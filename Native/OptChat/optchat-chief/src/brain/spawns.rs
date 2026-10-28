//! Section 9 in the brain: the spawns and their subagents (state.rs
//! `SpawnRecord`), each subagent's turn ends read from its acpmux session,
//! and the reports: each subagent's report reaches the chat as its own
//! message, `[id] report`, when it finishes (the reference client's `work`
//! message), queued like a human message (so on acpmux it stops a working
//! Chief between its tool calls, and the next turn takes it; otherwise it
//! starts a turn). Reports queued while the Chief is busy go into one turn.
//! The report of a run the user stopped (`session/cancel` in its pane) is
//! queued quiet: the next turn logs it, and it starts none.
//!
//! A report is the subagent's last finished reply: its final reply is its
//! report to the Chief (section 9's subagent prompt).

use cmux_chief::acp::{AcpmuxEvent, SessionStatus, SessionSummary};
use serde_json::{Value, json};

use super::children::{ended_replies, report_of};
use super::{Brain, Queued, Source};
use crate::fold::TurnFold;
use crate::state::{SpawnRecord, SpawnRef, SubRecord, SubStatus};
use crate::subagents::{PROMPT_PREFIX, SpawnPlan};

/// Characters of a task kept for `control status`.
const TASK_KEPT: usize = 600;

fn busy(status: SessionStatus) -> bool {
    matches!(status, SessionStatus::Running | SessionStatus::Waiting)
}

fn now_ms() -> u64 {
    super::now_ms()
}

/// A report carries another person's influence only when its subagent was
/// spawned under the spawn floor (policy `ask`, a turn another person
/// started): the turn that reads it refuses local effects. Any other report
/// is the owner's work and never holds the owner's next turn (the Chief
/// never asks, Lawrence 2026-10-20).
fn report_requires_approval(policy: Option<&str>) -> bool {
    policy == Some(crate::approval::ASK)
}

impl Brain {
    /// Where a spawn's subagents run: `place` (`cloud`/`local`), else the
    /// saved `control cloud` default, else the env's peer; None: here.
    pub(super) fn spawn_peer(
        &self,
        env: Option<&str>,
        place: Option<&str>,
    ) -> Result<Vec<String>, String> {
        let list = |p: &str| -> Vec<String> {
            p.split(',')
                .map(str::trim)
                .filter(|p| !p.is_empty())
                .map(str::to_owned)
                .collect()
        };
        let saved = self.state.cloud_peer.clone();
        let mut peers = match saved.as_deref() {
            Some(p) if !p.is_empty() => list(p),
            _ => env.map(list).unwrap_or_default(),
        };
        // v2: cloud by default. Nothing saved, no env peer and a pool tool
        // set up: each subagent gets its own VM (`needs_mac` keeps Mac
        // tasks here). A saved `control cloud off` stays off.
        if peers.is_empty()
            && saved.is_none()
            && self.cloud_vms.as_ref().is_some_and(|v| v.available())
        {
            peers = vec![crate::subagents::PER_AGENT.to_owned()];
        }
        match place {
            Some("local") => Ok(Vec::new()),
            Some("cloud") if peers.is_empty() => Err(
                "no cloud peer is set up: `control cloud PEER[,PEER...]` names the acpmux peers (`acpmux host ls`) cloud subagents run on".to_owned(),
            ),
            Some("cloud") => Ok(peers),
            Some(other) => Err(format!("spawn: no place {other}; cloud or local")),
            None if saved.as_deref() == Some("") => Ok(Vec::new()),
            None => Ok(peers),
        }
    }

    /// Live (starting or running) subagents on cloud peer `peer`.
    pub(super) fn live_on(&self, peer: &str) -> usize {
        self.state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| s.peer.as_deref() == Some(peer))
            .filter(|s| matches!(s.status, SubStatus::Starting | SubStatus::Running))
            .count()
    }

    /// B4: pauses each cloud peer's VM after `cloud_idle`
    /// (`cloud.autoPauseIdleSeconds`, 60 s) with no live subagent on it,
    /// once; [`CLOUD_TICK`](super::control::CLOUD_TICK) runs it. A subagent
    /// mid-turn (running, a tool, a prompt, a pending tell) is live, so its
    /// VM never pauses; the pool tool also refuses while a turn or a
    /// background process runs on the VM, and that pause is tried again.
    pub(super) fn cloud_tick(&mut self) {
        let Some(vms) = self.cloud_vms.clone() else {
            return;
        };
        let now = now_ms();
        let mut peers: Vec<String> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| !s.vm_deleted)
            .filter_map(|s| s.peer.clone())
            .filter(|p| !self.cloud_reaping.contains(p))
            .collect();
        peers.sort_unstable();
        peers.dedup();
        for peer in peers {
            if self.live_on(&peer) > 0 {
                self.cloud_idle_since.remove(&peer);
                continue;
            }
            if self.cloud_paused.contains(&peer) {
                continue;
            }
            // A subagent's own VM pauses as soon as its run ends (its final
            // report); a shared peer after `cloud.autoPauseIdleSeconds`.
            let own = crate::subagents::is_agent_peer(&peer);
            let wait = if own {
                0
            } else {
                self.cloud_idle.as_millis() as u64
            };
            let since = *self.cloud_idle_since.entry(peer.clone()).or_insert(now);
            if now.saturating_sub(since) < wait {
                continue;
            }
            self.cloud_paused.insert(peer.clone());
            self.cloud_idle_since.remove(&peer);
            if own {
                (self.log)(&format!("cloud: pausing {peer} (its subagent's run ended)"));
            } else {
                (self.log)(&format!(
                    "cloud: pausing {peer} (no live cloud subagent for {} s)",
                    self.cloud_idle.as_secs()
                ));
            }
            let vms = vms.clone();
            let log = self.log.clone();
            let tx = self.tx.clone();
            // The pool tool takes seconds: off the brain thread.
            let _ = std::thread::Builder::new()
                .name("cloud-pause".into())
                .spawn(move || {
                    let began = std::time::Instant::now();
                    match vms.pause(&peer) {
                        Ok(()) => log(&format!(
                            "cloud: paused {peer} in {} ms",
                            began.elapsed().as_millis()
                        )),
                        Err(e) => {
                            log(&format!("cloud: pause {peer}: {e}"));
                            let _ = tx.send(super::Input::CloudPauseFailed { peer });
                        }
                    }
                });
        }
    }

    /// One VM per subagent: deletes the own VM (`chief-sub-<id>`) of each
    /// subagent not live (not starting, queued or running) for
    /// `cloud_reap` (`cloud.deleteAfterPausedDays`), off the brain thread.
    /// The wait starts when the host first sees it not live and is saved
    /// with the subagent, so a host restart does not start it again. The
    /// pool tool refuses while a worktree there holds unpushed commits or
    /// edits (it pauses the VM instead); that delete is tried again a day
    /// later. [`CLOUD_TICK`](super::control::CLOUD_TICK) runs it.
    pub(super) fn cloud_reap_tick(&mut self) {
        let Some(vms) = self.cloud_vms.clone() else {
            return;
        };
        let now = now_ms();
        let reap = self.cloud_reap.as_millis() as u64;
        let mut due = Vec::new();
        let mut changed = false;
        for sub in self
            .state
            .spawns
            .values_mut()
            .flat_map(|r| r.subs.iter_mut())
            .filter(|s| !s.vm_deleted)
        {
            let Some(peer) = sub
                .peer
                .clone()
                .filter(|p| crate::subagents::is_agent_peer(p))
            else {
                continue;
            };
            let live = matches!(
                sub.status,
                SubStatus::Starting | SubStatus::Queued | SubStatus::Running
            );
            if live {
                changed |= sub.vm_idle_since.take().is_some();
                continue;
            }
            let since = *sub.vm_idle_since.get_or_insert_with(|| {
                changed = true;
                now
            });
            if now.saturating_sub(since) >= reap {
                due.push(peer);
            }
        }
        if changed {
            self.save();
        }
        for peer in due {
            if !self.cloud_reaping.insert(peer.clone()) {
                continue;
            }
            let vms = vms.clone();
            let log = self.log.clone();
            let tx = self.tx.clone();
            let _ = std::thread::Builder::new()
                .name("cloud-reap".into())
                .spawn(move || match vms.destroy(&peer) {
                    Ok(()) => {
                        log(&format!("cloud: deleted {peer} (its subagent is done)"));
                        let _ = tx.send(super::Input::CloudVmDeleted { peer });
                    }
                    Err(e) => {
                        log(&format!("cloud: delete {peer}: {e}"));
                        let _ = tx.send(super::Input::CloudVmDeleteFailed { peer });
                    }
                });
        }
    }

    /// Polls the fleet jobs cloud subagents wait on (`fleet-wait`), every
    /// `fleet_every`, off the brain thread.
    pub(super) fn fleet_tick(&mut self) {
        let Some(fleet) = self.fleet.clone() else {
            return;
        };
        let now = now_ms();
        if now.saturating_sub(self.fleet_polled_ms) < self.fleet_every.as_millis() as u64 {
            return;
        }
        self.fleet_polled_ms = now;
        let waiting: Vec<(String, Vec<String>)> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| !s.fleet_wait.is_empty() && !s.vm_deleted)
            .filter(|s| matches!(s.status, SubStatus::Done | SubStatus::Reported))
            .map(|s| (s.id.clone(), s.fleet_wait.clone()))
            .collect();
        for (id, jobs) in waiting {
            if !self.fleet_polling.insert(id.clone()) {
                continue;
            }
            let fleet = fleet.clone();
            let tx = self.tx.clone();
            let log = self.log.clone();
            let _ = std::thread::Builder::new()
                .name("fleet-wait".into())
                .spawn(move || {
                    for job in jobs {
                        match fleet.state(&job) {
                            Ok(state) if crate::fleet_wait::FINAL.contains(&state.as_str()) => {
                                let _ = tx.send(super::Input::FleetJobFinished {
                                    id: id.clone(),
                                    job,
                                    state,
                                });
                            }
                            Ok(_) => {}
                            Err(e) => log(&format!("fleet wait of {id}: {e}")),
                        }
                    }
                    let _ = tx.send(super::Input::FleetPolled { id });
                });
        }
    }

    /// Fleet job `job` that subagent `id` waits on ended: the subagent is
    /// told (its VM resumes first, as for any tell).
    pub(super) fn fleet_job_finished(&mut self, id: &str, job: &str, state: &str) {
        let Some(sub) = self.state.sub_mut(id) else {
            return;
        };
        let before = sub.fleet_wait.len();
        sub.fleet_wait.retain(|j| j != job);
        if sub.fleet_wait.len() == before {
            return;
        }
        self.save();
        (self.log)(&format!("fleet job {job} of {id} finished: {state}"));
        let message = format!(
            "fleet job {job} finished: {state}. Read its result (`cmux-ci status {job}`, `cmux-ci log {job}`) and go on with your task."
        );
        // The Chief's own tell path: it resumes the paused VM first, and the
        // key keeps a second poll from telling twice.
        let key = format!("fleet:{job}");
        if let Err(e) = self.tell_keyed(id, &message, Some(&key)) {
            (self.log)(&format!("fleet wake of {id}: {e}"));
        }
    }

    /// The pool tool refused to delete `peer` (unpushed work there): it is
    /// tried again a day later (or after `cloud_reap`, when shorter).
    pub(super) fn cloud_vm_delete_failed(&mut self, peer: &str) {
        self.cloud_reaping.remove(peer);
        let reap = self.cloud_reap.as_millis() as u64;
        let retry = reap.min(86_400_000);
        let now = now_ms();
        for sub in self
            .state
            .spawns
            .values_mut()
            .flat_map(|r| r.subs.iter_mut())
            .filter(|s| s.peer.as_deref() == Some(peer))
        {
            sub.vm_idle_since = Some(now.saturating_sub(reap).saturating_add(retry));
        }
        self.save();
    }

    /// `peer` (a subagent's own VM) is gone: its subagent is marked so.
    pub(super) fn cloud_vm_deleted(&mut self, peer: &str) {
        self.cloud_reaping.remove(peer);
        self.cloud_paused.remove(peer);
        self.cloud_idle_since.remove(peer);
        for sub in self
            .state
            .spawns
            .values_mut()
            .flat_map(|r| r.subs.iter_mut())
            .filter(|s| s.peer.as_deref() == Some(peer))
        {
            sub.vm_deleted = true;
        }
        self.save();
    }

    /// Subagent `id`'s own VM was not made: it runs here (`why` logged).
    pub(super) fn sub_placed_here(&mut self, id: &str, why: &str) {
        (self.log)(&format!("cloud: {id} runs here: {why}"));
        if let Some(sub) = self.state.sub_mut(id) {
            sub.peer = None;
            self.save();
        }
    }

    /// Subagent `id` holds sandbox key `key_id`.
    pub(super) fn sub_agent_key(&mut self, id: &str, key_id: String) {
        if let Some(sub) = self
            .state
            .spawns
            .values_mut()
            .flat_map(|r| r.subs.iter_mut())
            .find(|s| s.id == id)
        {
            sub.agent_key = Some(key_id);
            self.save();
        }
    }

    /// Subagent `id`'s sandbox key is revoked: forgotten.
    pub(super) fn agent_key_revoked(&mut self, id: &str) {
        self.agent_key_revoking.remove(id);
        self.agent_key_done_since.remove(id);
        if let Some(sub) = self
            .state
            .spawns
            .values_mut()
            .flat_map(|r| r.subs.iter_mut())
            .find(|s| s.id == id)
        {
            sub.agent_key = None;
            self.save();
        }
    }

    /// Revokes the sandbox key of each cloud subagent done (not starting,
    /// queued or running) for `agent_keys::REVOKE_AFTER_DONE`, off the brain
    /// thread; the service then deletes its VMs, and the pool tool removes
    /// the key file. A subagent told again within it keeps its key; one
    /// running again restarts the wait. [`CLOUD_TICK`](super::control::CLOUD_TICK) runs it.
    pub(super) fn agent_key_tick(&mut self) {
        let Some(keys) = self.agent_keys.clone() else {
            return;
        };
        let now = now_ms();
        let keyed: Vec<(String, String, Option<String>, bool)> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter_map(|s| {
                let live = matches!(
                    s.status,
                    SubStatus::Starting | SubStatus::Queued | SubStatus::Running
                );
                s.agent_key
                    .clone()
                    .map(|k| (s.id.clone(), k, s.peer.clone(), live))
            })
            .collect();
        for (id, key_id, peer, live) in keyed {
            if live {
                self.agent_key_done_since.remove(&id);
                continue;
            }
            if self.agent_key_revoking.contains(&id) {
                continue;
            }
            let since = *self.agent_key_done_since.entry(id.clone()).or_insert(now);
            if now.saturating_sub(since) < self.agent_key_grace.as_millis() as u64 {
                continue;
            }
            self.agent_key_revoking.insert(id.clone());
            let keys = keys.clone();
            let vms = self.cloud_vms.clone();
            let log = self.log.clone();
            let tx = self.tx.clone();
            let _ = std::thread::Builder::new()
                .name("agent-key-revoke".into())
                .spawn(move || {
                    match keys.revoke(&key_id) {
                        Ok(()) => {
                            log(&format!(
                                "agent key {key_id} of {id} revoked; its sandboxes are deleted"
                            ));
                            if let (Some(vms), Some(peer)) = (vms, peer)
                                && let Err(e) = vms.drop_agent_key(&peer, &id)
                            {
                                log(&format!("agent key file of {id} on {peer}: {e}"));
                            }
                            let _ = tx.send(super::Input::AgentKeyRevoked { id });
                        }
                        // Tried again next tick: the key stays recorded.
                        Err(e) => {
                            log(&format!("agent key {key_id} of {id}: revoke: {e}"));
                            let _ = tx.send(super::Input::AgentKeyRevokeFailed { id });
                        }
                    }
                });
        }
    }

    /// A revoke failed: the next tick tries again.
    pub(super) fn agent_key_revoke_failed(&mut self, id: &str) {
        self.agent_key_revoking.remove(id);
    }

    /// The pool tool refused or failed to pause `peer`: it is not paused,
    /// and its idle time starts again.
    pub(super) fn cloud_pause_failed(&mut self, peer: &str) {
        self.cloud_paused.remove(peer);
        self.cloud_idle_since.remove(peer);
    }

    /// The host stops: each cloud VM with no live subagent pauses now, on
    /// this thread (the process exits next); one with a subagent mid-turn
    /// keeps running, and its report waits in acpmux for the next host.
    pub(super) fn cloud_shutdown(&mut self) {
        let Some(vms) = self.cloud_vms.clone() else {
            return;
        };
        let mut peers: Vec<String> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter_map(|s| s.peer.clone())
            .collect();
        peers.sort_unstable();
        peers.dedup();
        for peer in peers {
            if self.live_on(&peer) > 0 || self.cloud_paused.contains(&peer) {
                continue;
            }
            let began = std::time::Instant::now();
            match vms.pause(&peer) {
                Ok(()) => {
                    self.cloud_paused.insert(peer.clone());
                    (self.log)(&format!(
                        "cloud: host stops: paused {peer} in {} ms",
                        began.elapsed().as_millis()
                    ));
                }
                Err(e) => (self.log)(&format!("cloud: host stops: pause {peer}: {e}")),
            }
        }
    }

    /// Gives a spawn its id and its subagents theirs (`a<N>`, unique per home),
    /// with the call's `place`
    /// (`cloud`, `local` or None) and VM `size`. With the peer list
    /// [`PER_AGENT`](crate::subagents::PER_AGENT) each subagent gets its
    /// own VM, `chief-sub-<id>`, at `size` or the size its task needs; a
    /// task that needs the Mac stays here unless `place` is `cloud`.
    pub(super) fn register_spawn_sized(
        &mut self,
        tasks: &[String],
        peers: &[String],
        place: Option<&str>,
        size: Option<&str>,
    ) -> Result<SpawnPlan, String> {
        if let Some(s) = size
            && !crate::subagents::SIZES.contains(&s)
        {
            return Err(format!(
                "spawn: no VM size {s}; one of {}",
                crate::subagents::SIZES.join(", ")
            ));
        }
        let per_agent = peers.len() == 1 && peers[0] == crate::subagents::PER_AGENT;
        if tasks.is_empty() {
            return Err("spawn needs at least one task".into());
        }
        let mut free = self
            .live_cap()
            .map_or(usize::MAX, |n| n.saturating_sub(self.live_subs()));
        // B4: each cloud subagent goes to the peer with the fewest live
        // ones (counting this spawn's), ties to the first listed.
        let mut load: Vec<usize> = peers.iter().map(|p| self.live_on(p)).collect();
        let mut pick = || -> Option<String> {
            let k = (0..peers.len()).min_by_key(|&k| (load[k], k))?;
            load[k] += 1;
            Some(peers[k].clone())
        };
        let chosen: Vec<Option<String>> = if per_agent {
            Vec::new()
        } else {
            tasks.iter().map(|_| pick()).collect()
        };
        for p in chosen.iter().flatten() {
            self.cloud_paused.remove(p);
            self.cloud_idle_since.remove(p);
        }
        // Never below an id already handed out: a reset or unreadable
        // counter must not give `a<N>` twice (persistent-ids-DESIGN.md).
        let prior = self.state.next_subagent;
        let first = self
            .state
            .next_subagent
            .max(highest_subagent(&self.state.spawns) + 1);
        let ids: Vec<String> = (0..tasks.len() as u64)
            .map(|k| format!("a{}", first + k))
            .collect();
        self.state.next_subagent = first + tasks.len() as u64;
        // One VM per subagent: its own peer, named after its id; a task that
        // needs the Mac (and was not sent to the cloud) runs here.
        let chosen: Vec<Option<String>> = if per_agent {
            ids.iter()
                .zip(tasks)
                .map(|(id, task)| {
                    (place == Some("cloud") || !crate::subagents::needs_mac(task))
                        .then(|| crate::subagents::agent_peer(id))
                })
                .collect()
        } else {
            chosen
        };
        let sizes: Vec<Option<String>> = chosen
            .iter()
            .zip(tasks)
            .map(|(p, task)| {
                p.as_ref().map(|_| {
                    size.map_or_else(
                        || crate::subagents::size_for(task).to_owned(),
                        str::to_owned,
                    )
                })
            })
            .collect();
        let spawn = format!("s{first}");
        let record = SpawnRecord {
            subs: ids
                .iter()
                .zip(tasks)
                .zip(&chosen)
                .map(|((id, task), peer)| {
                    // Over the cap it waits for a free slot; a cloud one
                    // (on a peer) takes none.
                    let status = if peer.is_some() {
                        SubStatus::Starting
                    } else if free > 0 {
                        free -= 1;
                        SubStatus::Starting
                    } else {
                        SubStatus::Queued
                    };
                    SubRecord {
                        id: id.clone(),
                        title: crate::workspaces::title(task),
                        task: task.chars().take(TASK_KEPT).collect(),
                        run_ms: now_ms(),
                        status,
                        peer: peer.clone(),
                        ..SubRecord::default()
                    }
                })
                .collect(),
            delivered: false,
            started_ms: now_ms(),
            turn: self.state.turn.as_ref().map(|t| t.key.clone()),
            answers: match self.state.turn.as_ref() {
                Some(turn) => turn.answers.clone(),
                None => self.state.last_answers.clone(),
            },
        };
        let queued: Vec<String> = record
            .subs
            .iter()
            .filter(|s| s.status == SubStatus::Queued)
            .map(|s| s.id.clone())
            .collect();
        self.state.spawns.insert(spawn.clone(), record);
        // The ids are durable before anyone sees them: a failed save hands
        // out none, so a crash can never give them again.
        if let Err(e) = self.file.save_with(&self.state, Vec::new()) {
            self.state.spawns.remove(&spawn);
            self.state.next_subagent = prior;
            return Err(format!("spawn not saved, no ids given: {e}"));
        }
        (self.log)(&format!("spawn {spawn}: {}", ids.join(", ")));
        Ok(SpawnPlan {
            spawn,
            ids,
            queued,
            limit: self.live_cap_source(),
            engine: self.spawn_engine(),
            peer: chosen.iter().flatten().next().cloned(),
            peers: chosen,
            sizes,
        })
    }

    pub(super) fn sub_queued(&mut self, id: &str, launch: crate::state::QueuedLaunch) {
        if let Some(sub) = self.state.sub_mut(id)
            && sub.status == SubStatus::Queued
        {
            sub.queued_launch = Some(launch);
            self.save();
        }
    }

    pub(super) fn sub_started(&mut self, id: &str, session_id: String, policy: Option<String>) {
        if let Some(sub) = self.state.sub_mut(id) {
            sub.session_id = Some(session_id);
            sub.policy = policy;
            if sub.status == SubStatus::Starting {
                sub.status = SubStatus::Running;
            }
            sub.active_ms = now_ms();
            sub.stuck_noted = false;
            // Tells wait until its task is sent (`sub_prompted`).
            sub.awaiting_task = true;
            self.save();
        }
    }

    /// Its first prompt is sent: messages told while it was starting
    /// follow it, in order.
    pub(super) fn sub_prompted(&mut self, id: &str) {
        if let Some(sub) = self.state.sub_mut(id) {
            sub.awaiting_task = false;
        }
        self.save();
        self.flush_inbox(id);
    }

    pub(super) fn sub_workspace(&mut self, id: &str, key: String, name: String) {
        self.sub_workspace_opened(id, key, name, true);
    }

    /// Its workspace exists; `at_start`: the spawn opened it (a subagent
    /// that finished meanwhile is closed under the close setting), not a
    /// `control show` the user asked for.
    pub(super) fn sub_workspace_opened(
        &mut self,
        id: &str,
        key: String,
        name: String,
        at_start: bool,
    ) {
        // A `control show` whose workspace a later `hide` (or failure)
        // already gave up: the record no longer names it, so it is closed,
        // not shown (the hide's close may have run before it existed).
        if !at_start
            && self
                .state
                .sub(id)
                .is_some_and(|(_, s)| s.workspace.as_deref() != Some(key.as_str()))
        {
            if let Some(workspaces) = self.workspaces.clone() {
                let (log, id) = (self.log.clone(), id.to_owned());
                std::thread::spawn(move || {
                    if let Err(e) = workspaces.close(&key) {
                        log(&format!(
                            "subagent {id}: closing its superseded workspace: {e}"
                        ));
                    }
                });
            }
            return;
        }
        let mut shown_session = None;
        let done = if let Some(sub) = self.state.sub_mut(id) {
            sub.workspace = Some(key);
            sub.title = name;
            shown_session = sub.session_id.clone().filter(|_| sub.peer.is_none());
            matches!(sub.status, SubStatus::Done | SubStatus::Reported)
        } else {
            false
        };
        self.save();
        // Its prompt shows in its tab now, with a working Allow button: it
        // waits for the person, not for the watchdog.
        if let Some(session) = shown_session {
            self.forget_unanswered_of(&session);
        }
        // It finished before its workspace was made.
        if done && at_start {
            self.mark_workspace(id, true);
        }
    }

    /// Where its workspace opens (`control show`), and its title.
    pub(super) fn sub_workspace_slot(
        &mut self,
        id: &str,
        name: String,
        slot: crate::state::WorkspaceSlot,
    ) {
        if let Some(sub) = self.state.sub_mut(id) {
            sub.workspace_slot = Some(slot);
            sub.title = name;
        }
        self.save();
    }

    /// Opening workspace `key` failed (at spawn or on `control show`): it is
    /// hidden, and the next `show` opens under a fresh key (a half-made
    /// workspace was closed under this one, and the daemon replays its
    /// mutations).
    pub(super) fn sub_workspace_failed(&mut self, id: &str, key: &str) {
        if let Some(sub) = self.state.sub_mut(id) {
            if sub.workspace.as_deref() == Some(key) {
                sub.workspace = None;
            }
            if sub.workspace_slot.as_ref().is_some_and(|s| s.key == key) {
                super::control::retire_slot_key(sub);
            }
        }
        self.save();
        self.rewatch_permission(id);
    }

    /// `id` lost its workspace (hidden, or its open failed): a prompt it
    /// still waits on has no Allow button any more, so it is watched again
    /// and denied once overdue, as for any subagent without a workspace.
    pub(super) fn rewatch_permission(&mut self, id: &str) {
        let Some((_, sub)) = self.state.sub(id) else {
            return;
        };
        if Self::approval_shown(sub) || sub.policy.as_deref() == Some(crate::approval::ASK) {
            return;
        }
        let (Some(session_id), Some(p)) = (sub.session_id.clone(), sub.permission.clone()) else {
            return;
        };
        self.watch_unanswered(
            crate::approval::Pending {
                session_id,
                permission_id: p.id,
                tool: crate::approval::tool_name(&p.request),
                request: p.request,
                child: Some(id.to_owned()),
            },
            "the app shows no working approval button for this subagent",
        );
    }

    pub(super) fn sub_failed(&mut self, id: &str, error: &str) {
        // A subagent that fails while the spawn floor is up (another
        // person's turn, or an `ask` child or subagent alive) keeps `ask`:
        // its failure text then holds the turn that reads it. The owner's own
        // failures never do (the Chief never asks, 2026-10-20).
        let floor = self.spawn_policy();
        let Some(sub) = self.state.sub_mut(id) else {
            return;
        };
        if let Some(floor) = floor
            && sub.policy.is_none()
        {
            sub.policy = Some(floor.to_owned());
        }
        sub.status = SubStatus::Done;
        sub.awaiting_task = false;
        sub.report = Some(format!("(did not start: {error})"));
        sub.stopped = false;
        let spawn = self.state.sub(id).map(|(s, _)| s.clone());
        self.save();
        if let Some(spawn) = spawn {
            self.deliver(&spawn);
        }
        self.start_queued();
        self.pause_own_vm(id);
    }

    pub(super) fn sub_answer(&mut self, id: &str, answer: &Result<Value, String>) {
        let mut fields = crate::subagents::answer_fields(answer);
        fields["id"] = json!(id);
        if let Some((spawn, _)) = self.state.sub(id) {
            fields["spawn"] = json!(spawn);
        }
        self.trace.emit("subagent.answer", fields);
        // A prompt the harness failed ends the run with a failure report,
        // never a subagent that runs forever.
        if let Err(e) = answer
            && self
                .state
                .sub(id)
                .is_some_and(|(_, s)| s.status == SubStatus::Running)
        {
            self.sub_done(id, format!("(failed: {e})"), false, None, None);
        }
    }

    /// A session changed: when it is a subagent's, its runs and turn ends
    /// are followed here. True when it was one.
    pub(super) fn sub_changed(&mut self, session: &SessionSummary) -> bool {
        let Some(id) = self.state.sub_by_session(&session.session_id) else {
            return false;
        };
        let Some(status) = self.state.sub(&id).map(|(_, s)| s.status) else {
            return true;
        };
        if let Some(sub) = self.state.sub_mut(&id) {
            sub.active_ms = now_ms();
            if session.pending_permissions == 0 {
                sub.permission = None;
            }
        }
        if busy(session.status) {
            // Running again: a tell, or the user writing in its chat.
            if matches!(status, SubStatus::Done | SubStatus::Reported) {
                if let Some(sub) = self.state.sub_mut(&id) {
                    sub.status = SubStatus::Running;
                    sub.run_ms = now_ms();
                    sub.stuck_noted = false;
                    sub.auto_continues = 0;
                    sub.continued_ms = 0;
                }
                self.save();
                self.mark_workspace(&id, false);
                self.trace.emit("subagent.resume", json!({"id": id}));
            }
            return true;
        }
        if status != SubStatus::Running {
            return true;
        }
        match session.status {
            SessionStatus::Idle | SessionStatus::Ready => self.finish_sub(&id, &session.session_id),
            SessionStatus::Closed | SessionStatus::Disconnected => {
                let report = format!(
                    "(stopped without a report: its session is {:?})",
                    session.status
                );
                self.sub_done(&id, report, false, None, None);
            }
            _ => {}
        }
        true
    }

    /// Reads a subagent's turn ends since its floor; when one ended, its
    /// last reply is its report.
    fn finish_sub(&mut self, id: &str, session_id: &str) {
        let floor = self.state.sub(id).map_or(0, |(_, s)| s.floor);
        let events = match self.agents.events(session_id, floor) {
            Ok(events) => events,
            Err(e) => {
                (self.log)(&format!("subagent {id}: its report could not be read: {e}"));
                return;
            }
        };
        let (replies, last_end, cancelled) = ended_replies(&events);
        // Idle before its prompt started (a new session is ready first); the
        // tick settles one that stays idle with no turn end (#7).
        let Some(last_end) = last_end else { return };
        self.trace_sub_events(id, &events, floor);
        let report = report_of(&replies, cancelled);
        self.sub_done(id, report, cancelled, Some(last_end), Some(&events));
    }

    pub(super) fn sub_done(
        &mut self,
        id: &str,
        report: String,
        stopped: bool,
        floor: Option<u64>,
        events: Option<&[AcpmuxEvent]>,
    ) {
        let Some((spawn, held)) = self
            .state
            .sub(id)
            .map(|(s, sub)| (s.clone(), sub.paused || sub.cancelled))
        else {
            return;
        };
        // control interrupt|restart with a message: the cut run reports
        // nothing; the message is its next prompt, sent now that it stopped.
        let follow = self.state.sub_mut(id).and_then(|s| s.after_stop.take());
        if let Some(message) = follow {
            if let Some(sub) = self.state.sub_mut(id) {
                if let Some(floor) = floor {
                    sub.floor = floor;
                }
                sub.status = SubStatus::Done;
            }
            self.save();
            match self.tell(id, &message) {
                Ok(_) => {
                    self.trace.emit("subagent.after_stop", json!({"id": id}));
                    return;
                }
                Err(e) => {
                    (self.log)(&format!("subagent {id}: its follow-up failed: {e}"));
                    // Kept: the inbox flush below sends it again.
                    self.keep_tell(id, message, &e);
                }
            }
        }
        // A run that stopped on an error: its report becomes "stopped: ..."
        // (quiet while an auto-resume is planned) and the continue is set up.
        // Never for one the Chief paused or cancelled.
        let planned = if held {
            None
        } else {
            self.plan_auto_resume(id, &report, stopped)
        };
        let resuming = planned.is_some();
        let (mut report, mut stopped) = match planned {
            Some((note, quiet)) => (note, quiet),
            None => (report, stopped),
        };
        if let Some(events) = events {
            let mut watch = crate::sub_watch::Watch::after(0);
            for e in events {
                watch.apply(e);
            }
            // #13: a stopped run says where it stopped.
            if report.starts_with("(stopped by the user)") {
                let state = watch.summary(self.now()).join("\n");
                report = format!("{report}\n{state}");
            }
            // #20: a short acknowledgement of a Chief message starts no turn.
            if !resuming && !stopped && watch.told_by_chief() && crate::sub_watch::is_ack(&report) {
                stopped = true;
                self.trace.emit("subagent.ack_quiet", json!({"id": id}));
            }
        }
        // A cloud subagent that ends on `fleet-wait: JOB` waits paused: no
        // Chief turn now; the host wakes it when the job ends.
        let own_vm = self
            .state
            .sub(id)
            .and_then(|(_, s)| s.peer.as_deref())
            .is_some_and(crate::subagents::is_agent_peer);
        let fleet_wait = if own_vm && self.fleet.is_some() {
            crate::fleet_wait::waits(&report)
        } else {
            Vec::new()
        };
        if !fleet_wait.is_empty() {
            stopped = true;
            (self.log)(&format!(
                "subagent {id} waits on fleet job(s) {}",
                fleet_wait.join(", ")
            ));
        }
        // A report that says its code is not landed gets the host's landing
        // follow-up first (no Chief turn); its next report reaches the Chief.
        let land_followup = !held
            && !resuming
            && !stopped
            && self
                .state
                .sub(id)
                .is_some_and(|(_, s)| s.land_followups < crate::sub_watch::LAND_FOLLOWUPS)
            && crate::sub_watch::unlanded(&report);
        if land_followup {
            stopped = true;
        }
        let run_ms = if let Some(sub) = self.state.sub_mut(id) {
            sub.fleet_wait = fleet_wait;
            sub.status = SubStatus::Done;
            sub.awaiting_task = false;
            sub.auto_continues = 0;
            sub.continued_ms = 0;
            sub.report = Some(report.clone());
            sub.stopped = stopped;
            if land_followup {
                sub.land_followups += 1;
                sub.inbox.push(crate::state::InboxMessage {
                    text: crate::sub_watch::LAND_FOLLOWUP.to_owned(),
                    at_ms: now_ms(),
                });
            }
            if let Some(floor) = floor {
                sub.floor = floor;
            }
            sub.run_ms
        } else {
            0
        };
        self.save();
        let (tools, tool_errors) = events.map_or((0, 0), |events| {
            let mut fold = TurnFold::new();
            for e in events {
                fold.apply(e);
            }
            fold.tool_counts()
        });
        self.trace.emit(
            "subagent.done",
            json!({
                "id": id,
                "spawn": spawn,
                "ms": now_ms().saturating_sub(run_ms),
                "report": self.trace.text(&report),
                "tools": tools,
                "tool_errors": tool_errors,
                "stopped": stopped,
            }),
        );
        (self.log)(&format!("subagent {id} finished"));
        if land_followup {
            (self.log)(&format!("subagent {id}: not landed, followed up"));
            self.trace.emit("subagent.land_followup", json!({"id": id}));
        }
        self.mark_workspace(id, true);
        self.deliver(&spawn);
        // A tell that could not reach its run goes as its next prompt.
        self.flush_inbox(id);
        self.start_queued();
        self.pause_own_vm(id);
    }

    /// Subagent `id`'s run ended: its own VM (`chief-sub-<id>`) pauses now,
    /// unless a tell already started it again.
    fn pause_own_vm(&mut self, id: &str) {
        let own = self
            .state
            .sub(id)
            .and_then(|(_, s)| s.peer.clone())
            .is_some_and(|p| crate::subagents::is_agent_peer(&p));
        if own {
            self.cloud_tick();
        }
    }

    /// A tell that neither steered nor prompted (``Input::TellUndelivered``):
    /// back into the inbox, before what came after it. A subagent whose run
    /// already ended gets it now; else with its next prompt (its run end
    /// flushes the inbox). The Chief gets a quiet note.
    pub(super) fn tell_undelivered(&mut self, id: &str, message: String, error: &str) {
        if self.keep_tell(id, message, error) {
            self.flush_inbox(id);
        }
    }

    /// `message` back first into subagent `id`'s inbox, with a quiet note to
    /// the Chief; true when the subagent's run has already ended.
    fn keep_tell(&mut self, id: &str, message: String, error: &str) -> bool {
        let Some(sub) = self.state.sub_mut(id) else {
            return false;
        };
        sub.inbox.insert(
            0,
            crate::state::InboxMessage {
                text: message,
                at_ms: now_ms(),
            },
        );
        let ended = matches!(sub.status, SubStatus::Done | SubStatus::Reported);
        self.save();
        self.trace
            .emit("tell.undelivered", json!({"id": id, "error": error}));
        self.queue(
            format!("[{id}] did not get your last message yet ({error}); it is kept and goes with its next prompt."),
            Source::Note,
        );
        ended
    }

    /// Auto-resume (auto_resume.rs) of subagent `id`, whose run just ended
    /// with `report`: None when there is nothing to do (a real report, a
    /// user stop, or auto-resume off); else the note that replaces its
    /// report (`stopped: ...`) and whether it is quiet (a continue is
    /// planned, so the Chief need not act).
    fn plan_auto_resume(
        &mut self,
        id: &str,
        report: &str,
        stopped: bool,
    ) -> Option<(String, bool)> {
        use crate::auto_resume::{Decision, StopKind, chief_note, classify, decide};
        let policy = self.resume_policy?;
        let kind = classify(report, stopped);
        let attempts = self.state.sub(id).map_or(0, |(_, s)| s.resume_attempts);
        if matches!(kind, StopKind::Done | StopKind::UserStopped) {
            if let Some(sub) = self.state.sub_mut(id) {
                sub.resume_attempts = 0;
                sub.moved = false;
                sub.moving = None;
            }
            return None;
        }
        // A network stop always waits on the probe (off this thread); it
        // returns at once when the endpoint answers.
        let decision = decide(&kind, attempts, &policy, false);
        if let Decision::Move { reason } = &decision {
            return Some(self.plan_move(id, reason));
        }
        let note = chief_note(&decision)?;
        self.trace.emit(
            "subagent.auto_resume",
            json!({"id": id, "kind": format!("{kind:?}"), "attempts": attempts, "decision": format!("{decision:?}")}),
        );
        // WARN: the error journal (`cmux errors`) harvests host.log lines by level word.
        (self.log)(&format!("WARN subagent {id}: {note}"));
        match decision {
            Decision::Report { .. } => {
                if let Some(sub) = self.state.sub_mut(id) {
                    sub.resume_attempts = 0;
                }
                Some((note, false))
            }
            Decision::Retry {
                reason,
                attempt,
                delay,
            } => {
                if let Some(sub) = self.state.sub_mut(id) {
                    sub.resume_attempts = attempt;
                }
                let (tx, id) = (self.tx.clone(), id.to_owned());
                std::thread::spawn(move || {
                    // A bounded backoff before the retry (auto_resume.rs).
                    std::thread::sleep(delay);
                    let _ = tx.send(super::Input::AutoResume {
                        id,
                        attempt,
                        reason,
                        after_network: false,
                        online: true,
                    });
                });
                Some((note, true))
            }
            // Planned above (plan_move).
            Decision::Move { .. } => None,
            Decision::WaitOnline { reason, attempt } => {
                if let Some(sub) = self.state.sub_mut(id) {
                    sub.resume_attempts = attempt;
                }
                let (tx, id, reach) = (self.tx.clone(), id.to_owned(), self.reach.clone());
                let settle = policy.backoff(1).min(std::time::Duration::from_secs(15));
                std::thread::spawn(move || {
                    let online = crate::auto_resume::wait_online(
                        &*reach,
                        crate::auto_resume::NETWORK_POLL,
                        crate::auto_resume::NETWORK_WAIT_MAX,
                        std::thread::sleep,
                    );
                    if online {
                        // Let the link settle before the request.
                        std::thread::sleep(settle);
                    }
                    let _ = tx.send(super::Input::AutoResume {
                        id,
                        attempt,
                        reason,
                        after_network: true,
                        online,
                    });
                });
                Some((note, true))
            }
        }
    }

    /// Subagent `id` stopped because its account hit a usage limit
    /// (`reason`): it continues in a new session on the harness the Chief's
    /// next turn takes, when that is another one and it was not just moved
    /// (the note is quiet then); else the stop is reported as it is.
    fn plan_move(&mut self, id: &str, reason: &str) -> (String, bool) {
        let (session, peer, moved) = self
            .state
            .sub(id)
            .map(|(_, s)| (s.session_id.clone(), s.peer.clone(), s.moved))
            .unwrap_or_default();
        let from = session
            .as_deref()
            .and_then(|sid| self.session_summary(sid))
            .map(|s| s.harness);
        let to = self.next_engine().0.harness;
        let target = from
            .clone()
            .filter(|from| peer.is_none() && !moved && !from.is_empty() && *from != to);
        self.trace.emit(
            "subagent.auto_move",
            json!({"id": id, "from": from, "to": to, "moving": target.is_some(), "moved_before": moved}),
        );
        let Some(from) = target else {
            if let Some(sub) = self.state.sub_mut(id) {
                sub.resume_attempts = 0;
            }
            let why = if peer.is_some() {
                "it runs on a cloud peer".to_owned()
            } else if moved {
                "it was already moved once".to_owned()
            } else if from.as_deref().is_none_or(str::is_empty) {
                "its harness is not known".to_owned()
            } else {
                format!("the Chief's own turns run on {to} too")
            };
            // WARN: the error journal (`cmux errors`) harvests host.log lines by level word.
            (self.log)(&format!(
                "WARN subagent {id}: usage limit, not moved ({why}): {reason}"
            ));
            return (
                format!(
                    "stopped: its account hit a usage limit ({reason}). It was not moved to another harness ({why}); switch the Chief's engine (`chief engine --harness ...`) and tell it to continue."
                ),
                false,
            );
        };
        if let Some(sub) = self.state.sub_mut(id) {
            sub.resume_attempts = 0;
            sub.moving = Some(to.clone());
        }
        (self.log)(&format!(
            "WARN subagent {id}: its account on {from} hit a usage limit; continuing it on {to}"
        ));
        let _ = self.tx.send(super::Input::AutoMove {
            id: id.to_owned(),
            harness: to.clone(),
        });
        (
            format!(
                "stopped: its account on {from} hit a usage limit, so it continues in a new session on {to}."
            ),
            true,
        )
    }

    /// The summary of acpmux session `id`: the one the brain follows, else
    /// acpmux's.
    fn session_summary(&self, id: &str) -> Option<SessionSummary> {
        self.sessions
            .get(id)
            .cloned()
            .or_else(|| self.agents.session(id).ok().flatten())
    }

    /// The engine of a subagent that starts on `harness`: the next turn's
    /// model and effort when it is that turn's harness.
    fn engine_on(&self, harness: &str) -> crate::subagents::SpawnEngine {
        let next = self.next_engine().0;
        let same = next.harness == harness;
        let family = self.family_of(harness);
        crate::subagents::SpawnEngine {
            harness: harness.to_owned(),
            model: next.model.filter(|_| same),
            effort: next.effort.filter(|_| same),
            other_family: (family != self.family_of(&self.settings.harness)).then_some(family),
        }
    }

    /// A move of `id` is due (`Input::AutoMove`): its earlier session's chat
    /// is saved to a file, and it is queued again with its task, that file
    /// and the new harness; the queue starts it in a new session.
    pub(super) fn auto_move_due(&mut self, id: &str, harness: &str) {
        let Some((_, sub)) = self.state.sub(id) else {
            return;
        };
        let current = sub.moving.as_deref() == Some(harness)
            && !sub.cancelled
            && !sub.paused
            && matches!(sub.status, SubStatus::Done | SubStatus::Reported);
        if !current {
            self.trace.emit(
                "subagent.auto_move.skip",
                json!({"id": id, "harness": harness, "status": format!("{:?}", sub.status)}),
            );
            // Not this move any more (it runs again, or was paused or
            // cancelled): a later restart must not start it.
            if let Some(sub) = self.state.sub_mut(id)
                && sub.moving.as_deref() == Some(harness)
            {
                sub.moving = None;
                self.save();
            }
            return;
        }
        let (task, session, policy) =
            (sub.task.clone(), sub.session_id.clone(), sub.policy.clone());
        let summary = session.as_deref().and_then(|s| self.session_summary(s));
        let from = summary
            .as_ref()
            .map_or("another harness", |s| s.harness.as_str())
            .to_owned();
        let cwd = summary
            .as_ref()
            .map(|s| s.cwd.clone())
            .filter(|c| !c.is_empty());
        let transcript = session.as_deref().and_then(|s| self.save_transcript(id, s));
        // Its harness process on the used-up account is no longer followed.
        if let Some(old) = session.as_deref()
            && let Err(e) = self.agents.end_session(old)
        {
            (self.log)(&format!("subagent {id}: ending its earlier session: {e}"));
        }
        let launch = crate::state::QueuedLaunch {
            task: crate::auto_resume::move_prompt(&task, &from, transcript.as_deref()),
            cwd,
            effort: None,
            floor: policy,
            harness: Some(harness.to_owned()),
        };
        if let Some(sub) = self.state.sub_mut(id) {
            sub.status = SubStatus::Queued;
            sub.queued_launch = Some(launch);
            sub.moving = None;
            sub.moved = true;
            sub.session_id = None;
            sub.floor = 0;
            sub.report = None;
            sub.stopped = false;
        }
        self.save();
        self.trace.emit(
            "subagent.auto_move.queued",
            json!({"id": id, "from": from, "to": harness}),
        );
        self.start_queued();
    }

    /// Subagent `id`'s whole chat in acpmux session `session`, in a file
    /// beside the turn sessions' directory; None when it could not be read
    /// or written (logged).
    fn save_transcript(&self, id: &str, session: &str) -> Option<std::path::PathBuf> {
        let events = match self.agents.events(session, 0) {
            Ok(events) => events,
            Err(e) => {
                (self.log)(&format!("subagent {id}: reading its chat to move it: {e}"));
                return None;
            }
        };
        let text = crate::agent_chat::render(&crate::agent_chat::entries(&events));
        let dir = self
            .settings
            .session_dir
            .parent()
            .unwrap_or(&self.settings.session_dir)
            .join("moved");
        let path = dir.join(format!("{id}-{}.md", now_ms()));
        let written = std::fs::create_dir_all(&dir).and_then(|()| std::fs::write(&path, text));
        match written {
            Ok(()) => Some(path),
            Err(e) => {
                (self.log)(&format!(
                    "subagent {id}: saving its chat to {}: {e}",
                    path.display()
                ));
                None
            }
        }
    }

    /// Re-arms the automatic continues a stopped host planned but never
    /// sent ([`crate::state::HostState::pending_auto_resumes`]). Each waits
    /// until the model endpoint answers, so a restart while offline still
    /// waits for the network, then continues as planned.
    pub(super) fn rearm_auto_resumes(&mut self) {
        let moves: Vec<(String, String)> = self
            .state
            .spawns
            .values()
            .flat_map(|r| &r.subs)
            .filter(|s| matches!(s.status, SubStatus::Done | SubStatus::Reported))
            .filter_map(|s| Some((s.id.clone(), s.moving.clone()?)))
            .collect();
        for (id, harness) in moves {
            (self.log)(&format!(
                "subagent {id}: its move to {harness} re-armed after a host restart"
            ));
            let _ = self.tx.send(super::Input::AutoMove { id, harness });
        }
        let Some(policy) = self.resume_policy else {
            return;
        };
        for (id, attempt) in self.state.pending_auto_resumes() {
            (self.log)(&format!(
                "subagent {id}: auto-resume {attempt} re-armed after a host restart"
            ));
            self.trace.emit(
                "subagent.auto_resume.rearm",
                json!({"id": id, "attempt": attempt}),
            );
            let (tx, reach) = (self.tx.clone(), self.reach.clone());
            let settle = policy.backoff(1).min(std::time::Duration::from_secs(15));
            std::thread::spawn(move || {
                let online = crate::auto_resume::wait_online(
                    &*reach,
                    crate::auto_resume::NETWORK_POLL,
                    crate::auto_resume::NETWORK_WAIT_MAX,
                    std::thread::sleep,
                );
                if online {
                    // A bounded pause so a restart loop does not hammer the model.
                    std::thread::sleep(settle);
                }
                let _ = tx.send(super::Input::AutoResume {
                    id,
                    attempt,
                    reason: String::new(),
                    after_network: false,
                    online,
                });
            });
        }
    }

    /// An auto-resume of `id` is due: it is told to continue (its chat shows
    /// the `[auto-resume N]` message), unless it runs again already, a newer
    /// stop replaced this one, or the network never came back (then the
    /// stop is reported).
    pub(super) fn auto_resume_due(
        &mut self,
        id: &str,
        attempt: u32,
        reason: &str,
        after_network: bool,
        online: bool,
    ) {
        let Some((_, sub)) = self.state.sub(id) else {
            return;
        };
        let current = sub.resume_attempts == attempt
            && matches!(sub.status, SubStatus::Done | SubStatus::Reported);
        if !current {
            self.trace.emit(
                "subagent.auto_resume.skip",
                json!({"id": id, "attempt": attempt, "status": format!("{:?}", sub.status)}),
            );
            return;
        }
        if !online {
            let spawn = self.state.sub(id).map(|(s, _)| s.clone());
            if let Some(sub) = self.state.sub_mut(id) {
                sub.resume_attempts = 0;
                sub.status = SubStatus::Done;
                sub.stopped = false;
                sub.report = Some(format!(
                    "stopped after a retryable network error. The model endpoint did not answer for {} min, so auto-resume stopped waiting; tell it to continue when the network is back.",
                    crate::auto_resume::NETWORK_WAIT_MAX.as_secs() / 60
                ));
            }
            self.save();
            if let Some(spawn) = spawn {
                self.deliver(&spawn);
            }
            return;
        }
        let message = crate::auto_resume::continue_prompt(reason, attempt, after_network);
        match self.tell(id, &message) {
            Ok(_) => {
                (self.log)(&format!("subagent {id}: auto-resume {attempt} sent"));
                self.trace.emit(
                    "subagent.auto_resume.sent",
                    json!({"id": id, "attempt": attempt, "after_network": after_network}),
                );
            }
            Err(e) => (self.log)(&format!("subagent {id}: auto-resume {attempt} failed: {e}")),
        }
    }

    /// The subagent's tool calls, model requests and the messages the user
    /// typed into its chat, into the trace (never into the memory).
    fn trace_sub_events(&self, id: &str, events: &[AcpmuxEvent], floor: u64) {
        if !self.trace.is_on() {
            return;
        }
        let scope = json!({"subagent": id});
        let mut fold = TurnFold::after(floor);
        for e in events {
            fold.apply(e);
            if e.dir == "mux" && e.kind == "user_message" {
                let prompt_id = e.msg.get("promptId").and_then(Value::as_str).unwrap_or("");
                if !prompt_id.starts_with(PROMPT_PREFIX) {
                    let text = user_text(&e.msg);
                    self.trace.emit(
                        "subagent.input",
                        json!({"id": id, "from": "user", "text": self.trace.text(&text)}),
                    );
                }
            }
        }
        crate::trace::tools(&self.trace, &scope, fold.take_tool_traces());
        crate::trace::requests(&self.trace, &scope, fold.requests());
    }

    /// Under the close setting, closes a finished subagent's workspace.
    /// Its name is never changed (Lawrence 2026-10-19: "I don't like the
    /// checkmark"): the chat tab's own idle state shows that it is done, and
    /// a name the user or the Chief gave it stays.
    fn mark_workspace(&mut self, id: &str, done: bool) {
        if !(done && self.sub_close_on_finish) {
            return;
        }
        let (Some(workspaces), Some((_, sub))) = (self.workspaces.clone(), self.state.sub(id))
        else {
            return;
        };
        let Some(key) = sub.workspace.clone() else {
            return;
        };
        if let Some(sub) = self.state.sub_mut(id) {
            sub.workspace = None;
            super::control::retire_slot_key(sub);
        }
        self.save();
        let (log, id) = (self.log.clone(), id.to_owned());
        std::thread::spawn(move || {
            if let Err(e) = workspaces.close(&key) {
                log(&format!("subagent {id}: closing its workspace: {e}"));
            }
        });
    }

    /// Queues each finished subagent's report of `spawn` as its own item
    /// (or updates the one still queued). A stopped run's is quiet.
    pub(super) fn deliver(&mut self, spawn: &str) {
        let Some(record) = self.state.spawns.get(spawn) else {
            return;
        };
        let show = self.chief.show_after_report;
        let done: Vec<(String, String, u64, bool, bool)> = record
            .subs
            .iter()
            .filter(|s| s.status == SubStatus::Done)
            .map(|s| {
                let report = s.report.as_deref().unwrap_or("");
                let footer = crate::agent_chat::footer(&s.id);
                // What the work left to show, for the "After work" rule; a
                // stopped run's quiet report shows nothing.
                let block = (show && !s.stopped)
                    .then(|| crate::show::block(report))
                    .flatten()
                    .map(|b| format!("\n{b}"))
                    .unwrap_or_default();
                (
                    s.id.clone(),
                    format!("[{}] {report}\n{footer}{block}", s.id),
                    s.floor,
                    report_requires_approval(s.policy.as_deref()),
                    s.stopped,
                )
            })
            .collect();
        for (id, text, floor, requires_approval, quiet) in done {
            let source = Source::Spawn(SpawnRef {
                spawn: spawn.to_owned(),
                subs: vec![(id.clone(), floor)],
                requires_approval,
                quiet,
            });
            // On its way into the running turn (a steer not read yet): it is
            // logged when the harness reads it, never queued twice.
            let steering = self.steering.iter().any(|st| {
                st.items.iter().any(|q| {
                    matches!(&q.source, Source::Spawn(r) if r.spawn == spawn && r.subs.iter().any(|(s, _)| *s == id))
                })
            });
            if steering {
                continue;
            }
            let queued = self.queue.iter().position(|q| {
                matches!(&q.source, Source::Spawn(r) if r.spawn == spawn && r.subs.iter().any(|(s, _)| *s == id))
            });
            match queued {
                Some(k) => {
                    self.queue[k] = Queued {
                        text,
                        source,
                        images: Vec::new(),
                        conversation: None,
                        logged: false,
                    }
                }
                None => {
                    (self.log)(&format!("subagent {id}: queued its report"));
                    self.queue(text, source);
                }
            }
        }
    }

    /// The report reached the log (as `user`): the trace's `spawn.report`.
    pub(super) fn trace_report_logged(&self, r: &SpawnRef, text: &str) {
        let started = self.state.spawns.get(&r.spawn).map_or(0, |s| s.started_ms);
        self.trace.emit(
            "spawn.report",
            json!({
                "spawn": r.spawn,
                "ids": r.subs.iter().map(|(id, _)| id).collect::<Vec<_>>(),
                "text": self.trace.text(text),
                "ms_since_spawn": now_ms().saturating_sub(started),
            }),
        );
    }

    /// `tell(id, message, key)`: never fails for a known subagent. One that
    /// has no session yet (queued or starting) or is paused keeps it in its
    /// saved inbox, delivered in order the moment it can take it; a queued
    /// one gets it with its task. A repeat of `key` is not sent again.
    pub(super) fn tell_keyed(
        &mut self,
        id: &str,
        message: &str,
        key: Option<&str>,
    ) -> Result<String, String> {
        self.tell_with(id, message, key, false)
    }

    /// `tell_keyed` with `queue` (true: wait for the running turn, a
    /// low-priority FYI; false: steer it in, else interrupt the turn).
    pub(super) fn tell_with(
        &mut self,
        id: &str,
        message: &str,
        key: Option<&str>,
        queue: bool,
    ) -> Result<String, String> {
        let Some((_, sub)) = self.state.sub(id) else {
            return Err(format!("no subagent {id}"));
        };
        if let Some(key) = key
            && sub.tell_keys.iter().any(|k| k == key)
        {
            return Ok(format!(
                "outcome: noop. {id} already has this message (key {key}); it was not sent again"
            ));
        }
        let hold = sub.session_id.is_none()
            || sub.awaiting_task
            || sub.paused
            || sub.status == SubStatus::Queued;
        let cancelled = sub.cancelled;
        let peer = sub.peer.clone();
        if sub.vm_deleted {
            return Ok(format!(
                "outcome: refused. {id} finished and its cloud VM {} was deleted after its work was pushed; spawn a new subagent for more work",
                peer.as_deref().unwrap_or("?")
            ));
        }
        // B4: its VM was paused while it was idle; it resumes before the
        // message (a rare tell to a finished cloud subagent, seconds).
        if !cancelled
            && let Some(peer) = peer.filter(|p| self.cloud_paused.contains(p))
            && let Some(vms) = self.cloud_vms.clone()
        {
            let began = std::time::Instant::now();
            vms.resume(&peer)
                .map_err(|e| format!("{id}'s cloud VM {peer} did not resume: {e}"))?;
            (self.log)(&format!(
                "cloud: resumed {peer} for a tell to {id} in {} ms",
                began.elapsed().as_millis()
            ));
            self.cloud_paused.remove(&peer);
            self.cloud_idle_since.remove(&peer);
        }
        if cancelled {
            return Ok(format!(
                "outcome: refused. {id} was cancelled; control(action: \"restart\", id: \"{id}\") brings it back"
            ));
        }
        // The messages this tell is for: its next report answers them, in
        // their thread (chief-replies-reactions-DESIGN.md).
        let told_for = self
            .state
            .turn
            .as_ref()
            .map(|t| t.answers.clone())
            .unwrap_or_default();
        if !told_for.is_empty()
            && let Some(sub) = self.state.sub_mut(id)
        {
            sub.answers = told_for;
        }
        if let Some(key) = key
            && let Some(sub) = self.state.sub_mut(id)
        {
            sub.tell_keys.push(key.to_owned());
            let over = sub
                .tell_keys
                .len()
                .saturating_sub(crate::state::TELL_KEYS_KEPT);
            sub.tell_keys.drain(..over);
        }
        if hold {
            let (status, paused, waiting) = {
                let sub = self.state.sub_mut(id).expect("checked above");
                sub.inbox.push(crate::state::InboxMessage {
                    text: message.to_owned(),
                    at_ms: now_ms(),
                });
                (sub.status, sub.paused, sub.inbox.len())
            };
            self.save();
            self.trace.emit(
                "tell.queued",
                json!({"id": id, "waiting": waiting, "message": self.trace.text(message)}),
            );
            let why = if paused {
                "it is paused; it gets it on control resume".to_owned()
            } else if status == SubStatus::Queued {
                "it is queued; the message goes in with its task when it starts".to_owned()
            } else {
                "it is starting; it gets it the moment its session exists".to_owned()
            };
            return Ok(format!(
                "outcome: queued. Queued for delivery to {id} ({waiting} waiting): {why}. You get a note when it is delivered."
            ));
        }
        self.tell_mode(id, message, queue)
            .map(|answer| format!("outcome: done. {answer}"))
    }

    /// `peers` for subagent `caller`: the subagents at work (starting,
    /// queued, running, or with a report not read yet), one line each, the
    /// caller marked; then how many finished.
    pub(super) fn agents_list(&self, caller: &str) -> String {
        let mut lines = Vec::new();
        let mut finished = 0usize;
        for sub in self.state.spawns.values().flat_map(|r| r.subs.iter()) {
            if sub.cancelled || sub.status == SubStatus::Reported {
                finished += 1;
                continue;
            }
            let state = match sub.status {
                SubStatus::Starting => "starting",
                SubStatus::Queued => "queued",
                SubStatus::Running if sub.paused => "paused",
                SubStatus::Running => "at work",
                SubStatus::Done => "finished, report not read yet",
                SubStatus::Reported => "finished",
            };
            // A record from before 2026-10-21 carries its workspace's `aN · ` id prefix.
            let title = sub
                .title
                .split_once(" · ")
                .filter(|(id, _)| *id == sub.id)
                .map_or(sub.title.as_str(), |(_, t)| t);
            let you = if sub.id == caller { " (you)" } else { "" };
            let workspace = sub
                .workspace
                .as_deref()
                .map(|w| format!(", workspace {w}"))
                .unwrap_or_default();
            lines.push(format!("- {}{you}: {title} ({state}{workspace})", sub.id));
        }
        if lines.is_empty() {
            lines.push("No other subagent is at work.".to_owned());
        }
        lines.push(format!(
            "{finished} more finished. tell(id, message) sends one a message from you; zoom(\"aN\") reads its chat."
        ));
        lines.join("\n")
    }

    /// `tell` from subagent `from` to subagent `id` (acp-chief-issues.md
    /// #11): `tell_keyed` with a first line that names the sender, so the
    /// receiver knows who asks and how to answer. Never to itself.
    pub(super) fn peer_tell(
        &mut self,
        from: &str,
        id: &str,
        message: &str,
        key: Option<&str>,
    ) -> Result<String, String> {
        if from == id {
            return Err(format!("tell: {id} is you; write to Chief in your report"));
        }
        if self.state.sub(from).is_none() {
            return Err(format!("tell: no subagent {from} sends it"));
        }
        let text = format!(
            "Message from {from} (another subagent of Chief; answer it with tell(\"{from}\", ...) when it asks something):\n\n{message}"
        );
        // A peer never cuts another subagent's turn: it waits when the
        // agent cannot take it mid-turn (a `queue` tell).
        let answer = self.tell_with(id, &text, key, true)?;
        self.trace.emit(
            "tell.peer",
            json!({"from": from, "id": id, "message": self.trace.text(message)}),
        );
        Ok(answer)
    }

    /// Delivers subagent `id`'s inbox now that it can take it (its session
    /// exists, it is not paused), in order, as one message; a quiet note
    /// tells the Chief.
    pub(super) fn flush_inbox(&mut self, id: &str) {
        let messages = match self.state.sub_mut(id) {
            Some(sub)
                if sub.session_id.is_some()
                    && !sub.awaiting_task
                    && !sub.paused
                    // A move is planned: the inbox goes with its new
                    // session's task, never to the used-up account.
                    && sub.moving.is_none()
                    && !sub.inbox.is_empty() =>
            {
                std::mem::take(&mut sub.inbox)
            }
            _ => return,
        };
        self.save();
        let text = inbox_text(&messages);
        // Held for a subagent that was starting, queued or paused: they were
        // written to follow its task (or its resume), so they wait for that
        // turn instead of cutting it.
        match self.tell_mode(id, &text, true) {
            Ok(_) => {
                self.trace
                    .emit("tell.delivered", json!({"id": id, "count": messages.len()}));
                self.queue(
                    format!("[{id}] got {} queued message(s) from you.", messages.len()),
                    Source::Note,
                );
            }
            Err(e) => {
                (self.log)(&format!("subagent {id}: delivering its inbox: {e}"));
                if let Some(sub) = self.state.sub_mut(id) {
                    let mut back = messages;
                    back.append(&mut sub.inbox);
                    sub.inbox = back;
                }
                self.save();
            }
        }
    }

    /// `tell(id, message)`: the default `tell_mode` (it interrupts).
    pub(super) fn tell(&mut self, id: &str, message: &str) -> Result<String, String> {
        self.tell_mode(id, message, false)
    }

    /// A message to the subagent's session. Into a running turn it is
    /// steered (read between its tool calls); when the agent cannot steer
    /// now, the turn is interrupted and the message is its next prompt
    /// (`tell_unsteered`), or with `queue` it waits for the turn to end
    /// (acpmux queues it). An idle session runs it as a new turn.
    pub(super) fn tell_mode(
        &mut self,
        id: &str,
        message: &str,
        queue: bool,
    ) -> Result<String, String> {
        let (spawn, session) = match self.state.sub(id) {
            Some((spawn, sub)) => (
                spawn.clone(),
                sub.session_id
                    .clone()
                    .ok_or_else(|| format!("{id} has no session yet"))?,
            ),
            None => return Err(format!("no subagent {id}")),
        };
        // A `queue` tell is `fyi:`, so a reconnect never flushes it as an
        // interrupt (`flush_queued_tells` takes `tell:` ones only).
        let kind = if queue { "fyi" } else { "tell" };
        let prompt_id = format!("{PROMPT_PREFIX}{kind}:{id}:{}", now_ms());
        let blocks = vec![json!({"type": "text", "text": message})];
        let running = self
            .state
            .sub(id)
            .is_some_and(|(_, s)| matches!(s.status, SubStatus::Running | SubStatus::Starting));
        let (agents, forward, sub_id) = (self.agents.clone(), self.tx.clone(), id.to_owned());
        let text = message.to_owned();
        let steered = if running {
            // Reference parity S4: into the running session, read between
            // its tool calls. One that cannot steer now is interrupted, and
            // the message is its next prompt (user 2026-10-20: "interrupt
            // instead of queuing"); a `queue` tell waits after the turn.
            let log = self.log.clone();
            let message = message.to_owned();
            std::thread::spawn(move || {
                // The Chief's own tell is read now: acpmux stops the agent's current step
                // for it, as the pane's Send now does (Lawrence 2026-10-26: "interrupt by
                // default"; a long `cmux-ci wait` no longer holds it). A `queue` tell (a
                // peer's message, an FYI) waits for the step.
                let steered = if queue {
                    agents.steer(&session, blocks.clone(), &prompt_id)
                } else {
                    agents.steer_now(&session, blocks.clone(), &prompt_id)
                };
                if let Err(e) = steered {
                    if !queue {
                        log(&format!(
                            "subagent {sub_id}: the tell could not be steered ({e}); its turn is interrupted"
                        ));
                        let _ = forward.send(super::Input::TellUnsteered {
                            id: sub_id,
                            session,
                            message,
                        });
                        return;
                    }
                    log(&format!(
                        "subagent {sub_id}: the tell could not be steered ({e}); it goes after the current turn"
                    ));
                    let back = forward.clone();
                    if let Err(e) = tell_prompt(
                        &*agents,
                        &session,
                        blocks,
                        &prompt_id,
                        forward,
                        sub_id.clone(),
                    ) {
                        log(&format!(
                            "subagent {sub_id}: the tell did not reach it: {e}; it is kept for its next prompt"
                        ));
                        let _ = back.send(super::Input::TellUndelivered {
                            id: sub_id,
                            message: text,
                            error: e,
                        });
                    }
                }
            });
            true
        } else {
            tell_prompt(&*agents, &session, blocks, &prompt_id, forward, sub_id)?;
            false
        };
        let resumed = if let Some(sub) = self.state.sub_mut(id)
            && sub.status != SubStatus::Running
        {
            sub.status = SubStatus::Running;
            sub.run_ms = now_ms();
            true
        } else {
            false
        };
        self.save();
        if resumed {
            self.mark_workspace(id, false);
        }
        self.trace.emit(
            "tell",
            json!({"id": id, "spawn": spawn, "from": "chief", "steered": steered, "queue": queue, "message": self.trace.text(message)}),
        );
        let answer = if steered && queue {
            format!("sent to {id}; read between tool calls or after its turn")
        } else if steered {
            format!(
                "sent to {id}; its current step stops so it reads it now (a running subagent or background shell runs on), else its turn restarts with it"
            )
        } else {
            format!("sent to {id}; read after its current step")
        };
        Ok(answer)
    }

    /// A tell whose steer the running turn refused (`tell_mode`): the turn
    /// is interrupted as `control interrupt` does it (`after_stop`, then
    /// `session/cancel`), so the message is its next prompt and the cut run
    /// reports nothing. A second one while the stop is pending joins the
    /// same next prompt. One that ended meanwhile gets it as a new turn;
    /// when the cancel fails it waits after the turn, as a `queue` tell.
    pub(super) fn tell_unsteered(&mut self, id: &str, session: &str, message: &str) {
        let Some((_, sub)) = self.state.sub(id) else {
            return;
        };
        let same = sub.session_id.as_deref() == Some(session);
        let running = same && sub.status == SubStatus::Running && !sub.paused && !sub.cancelled;
        if !running {
            if same
                && !sub.cancelled
                && let Err(e) = self.tell(id, message)
            {
                (self.log)(&format!("subagent {id}: the tell did not reach it: {e}"));
                self.tell_undelivered(id, message.to_owned(), &e);
            }
            return;
        }
        let pending = sub.after_stop.is_some();
        if let Some(sub) = self.state.sub_mut(id) {
            sub.after_stop = Some(match sub.after_stop.take() {
                Some(earlier) => format!("{earlier}\n\n{message}"),
                None => message.to_owned(),
            });
        }
        self.save();
        if pending {
            self.trace
                .emit("tell.interrupt", json!({"id": id, "joined": true}));
            return;
        }
        match self.agents.cancel(session) {
            Ok(()) => self
                .trace
                .emit("tell.interrupt", json!({"id": id, "joined": false})),
            Err(e) => {
                (self.log)(&format!(
                    "subagent {id}: the tell could not interrupt it ({e}); it goes after the current turn"
                ));
                let text = self
                    .state
                    .sub_mut(id)
                    .and_then(|s| s.after_stop.take())
                    .unwrap_or_else(|| message.to_owned());
                self.save();
                let prompt_id = format!("{PROMPT_PREFIX}tell:{id}:{}", now_ms());
                let blocks = vec![json!({"type": "text", "text": text.clone()})];
                if let Err(e) = tell_prompt(
                    &*self.agents,
                    session,
                    blocks,
                    &prompt_id,
                    self.tx.clone(),
                    id.to_owned(),
                ) {
                    (self.log)(&format!("subagent {id}: the tell did not reach it: {e}"));
                    self.tell_undelivered(id, text, &e);
                }
            }
        }
    }

    /// Chief tells an older host left in a running subagent's acpmux queue
    /// (before tell interrupted by default): taken out of the queue and
    /// sent again now, as one default tell, so none waits behind a long
    /// turn. Read from the session's events since the subagent's floor.
    pub(super) fn flush_queued_tells(&mut self, id: &str) {
        let Some((_, sub)) = self.state.sub(id) else {
            return;
        };
        let Some(session) = sub.session_id.clone() else {
            return;
        };
        if sub.status != SubStatus::Running || sub.paused || sub.cancelled {
            return;
        }
        let events = match self.agents.events(&session, sub.floor) {
            Ok(events) => events,
            Err(e) => {
                (self.log)(&format!(
                    "subagent {id}: its queued tells could not be read: {e}"
                ));
                return;
            }
        };
        let mine = format!("{PROMPT_PREFIX}tell:");
        let mut waiting: Vec<(String, String)> = Vec::new();
        for e in &events {
            let Some(prompt) = e.msg.get("promptId").and_then(Value::as_str) else {
                continue;
            };
            match e.kind.as_str() {
                "queued" if prompt.starts_with(&mine) => {
                    waiting.retain(|(p, _)| p != prompt);
                    waiting.push((prompt.to_owned(), user_text(&e.msg)));
                }
                "user_message" | "queue_removed" | "prompt_refused" => {
                    waiting.retain(|(p, _)| p != prompt);
                }
                _ => {}
            }
        }
        let mut texts = Vec::new();
        for (prompt, text) in waiting {
            match self.agents.remove_queued(&session, &prompt) {
                Ok(true) => texts.push(crate::state::InboxMessage {
                    text,
                    at_ms: now_ms(),
                }),
                Ok(false) => {}
                Err(e) => {
                    (self.log)(&format!(
                        "subagent {id}: its queued tell {prompt} stays queued: {e}"
                    ));
                }
            }
        }
        if texts.is_empty() {
            return;
        }
        let text = inbox_text(&texts);
        self.trace
            .emit("tell.flushed", json!({"id": id, "count": texts.len()}));
        if let Err(e) = self.tell(id, &text) {
            (self.log)(&format!(
                "subagent {id}: its flushed tells did not reach it: {e}"
            ));
        }
    }

    /// After a reconnect: subagents that finished or vanished meanwhile.
    pub(super) fn reconcile_spawns(&mut self, sessions: &[SessionSummary]) {
        // A host that stopped between a session and its task: nothing will
        // send that task now, so its tells go as they come.
        let held: Vec<String> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| s.awaiting_task)
            .map(|s| s.id.clone())
            .collect();
        for id in held {
            self.sub_prompted(&id);
            self.stop_if_cancelled(&id);
        }
        let open: Vec<(String, Option<String>)> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| matches!(s.status, SubStatus::Starting | SubStatus::Running))
            .map(|s| (s.id.clone(), s.session_id.clone()))
            .collect();
        for (id, session) in open {
            match session {
                None => self.sub_done(
                    &id,
                    "(did not start: the Chief host stopped while starting it)".into(),
                    false,
                    None,
                    None,
                ),
                Some(session) => match sessions.iter().find(|s| s.session_id == session) {
                    Some(summary) => {
                        self.sub_changed(summary);
                    }
                    None => self.sub_done(
                        &id,
                        "(gone: its session no longer exists, so no report will come)".into(),
                        false,
                        None,
                        None,
                    ),
                },
            }
        }
        let spawns: Vec<String> = self.state.spawns.keys().cloned().collect();
        for spawn in spawns {
            self.deliver(&spawn);
        }
        let running: Vec<String> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| s.status == SubStatus::Running && s.session_id.is_some())
            .map(|s| s.id.clone())
            .collect();
        for id in running {
            self.flush_queued_tells(&id);
        }
        self.start_queued();
    }

    /// The live cap: `control cap` (0: none) over the env's.
    pub(super) fn live_cap(&self) -> Option<usize> {
        self.live_cap_source().map(crate::subagents::LiveCap::n)
    }

    /// The live cap with where it came from (`control cap` over the env).
    pub(super) fn live_cap_source(&self) -> Option<crate::subagents::LiveCap> {
        use crate::subagents::LiveCap;
        match self.state.live_cap {
            Some(0) => None,
            Some(n) => Some(LiveCap::Control(n)),
            None => self.max_live.map(LiveCap::Env),
        }
    }

    /// Subagents starting or running now on this machine (cloud ones, on a
    /// peer, take no slot).
    pub(super) fn live_subs(&self) -> usize {
        self.state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| s.peer.is_none())
            .filter(|s| s.at_work())
            .count()
    }

    /// Starts queued subagents, oldest first, while slots are free.
    pub(super) fn start_queued(&mut self) {
        while self.live_cap().is_none_or(|n| self.live_subs() < n) {
            let next = self
                .state
                .spawns
                .iter()
                .flat_map(|(spawn, r)| r.subs.iter().map(move |s| (spawn, s)))
                .filter(|(_, s)| s.status == SubStatus::Queued && !s.cancelled && !s.paused)
                .min_by_key(|(_, s)| {
                    (
                        -s.priority,
                        s.id.trim_start_matches('a')
                            .parse::<u64>()
                            .unwrap_or(u64::MAX),
                    )
                })
                .map(|(spawn, s)| crate::subagents::QueuedStart {
                    id: s.id.clone(),
                    spawn: spawn.clone(),
                    launch: s.queued_launch.clone(),
                    engine: None,
                    extra: (!s.inbox.is_empty()).then(|| inbox_text(&s.inbox)),
                });
            let Some(mut queued) = next else { return };
            queued.engine = match queued.launch.as_ref().and_then(|l| l.harness.as_deref()) {
                Some(harness) => Some(self.engine_on(harness)),
                None => self.spawn_engine(),
            };
            let id = queued.id.clone();
            let sent = self
                .sub_starter
                .as_ref()
                .is_some_and(|starter| starter.send(queued).is_ok());
            if !sent {
                self.sub_failed(&id, "this Chief host cannot start queued subagents");
                continue;
            }
            let mut delivered = 0;
            if let Some(sub) = self.state.sub_mut(&id) {
                sub.status = SubStatus::Starting;
                sub.run_ms = now_ms();
                sub.queued_launch = None;
                // Its inbox went in with its task.
                delivered = sub.inbox.len();
                sub.inbox.clear();
            }
            if delivered > 0 {
                self.queue(
                    format!("[{id}] got {delivered} queued message(s) from you with its task."),
                    Source::Note,
                );
            }
            self.save();
            (self.log)(&format!("subagent {id}: a slot is free, starting it"));
        }
    }

    /// `text` with every mention of this Chief's subagents written as its link
    /// (`workspaces::link_subagents`): the user's reply shows them as links
    /// whether or not the model wrote one.
    ///
    /// Then the last pass (`reply_links::link_refs`): a bare cmux id (`ws_…`, `tab_…`,
    /// `pane_…`) and a path that exists on this Mac become their `cmux://` and `file://` links
    /// (Lawrence 2026-10-26: "reply with links to stuff properly").
    pub(super) fn link_subagents(&self, text: &str) -> String {
        let linked = crate::workspaces::link_subagents(text, &self.settings.parent, |id| {
            self.state.sub(id).and_then(|(_, s)| s.session_id.clone())
        });
        let home = std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .unwrap_or_default();
        // Paths only on a Chief host on the person's Mac: a cloud VM's paths are not files
        // that Home or iOS can open as `file://`.
        let mac = cfg!(target_os = "macos");
        crate::reply_links::link_refs(&linked, &home, &|p| mac && p.exists())
    }

    /// chief.stop {name}: subagent `name` stops as with chief.stop (its
    /// report comes quiet), the reference's "Stopped by the user: X.".
    pub(super) fn stop_subagent(&mut self, name: &str) -> Value {
        let live = self.state.sub(name).is_some_and(|(_, s)| {
            matches!(
                s.status,
                SubStatus::Starting | SubStatus::Running | SubStatus::Queued
            )
        });
        if !live {
            return json!({"stopped": false, "error": format!("no subagent {name} at work")});
        }
        let StopPick {
            stopped,
            starting,
            errors,
        } = self.stop_subagents_where(|id| id == name);
        if stopped.is_empty() {
            let error = errors
                .into_iter()
                .next()
                .unwrap_or_else(|| format!("no subagent {name} at work"));
            return json!({"stopped": false, "error": error});
        }
        (self.log)(&format!("the owner stopped subagent {name}"));
        self.save();
        self.start_queued();
        let note = starting_note(&starting)
            .unwrap_or_else(|| format!("Stopped by the user: {}.", stopped.join(", ")));
        json!({"stopped": true, "subagents": stopped, "note": note})
    }

    /// chief.stop {all: true} ("Stop all agents", never a plain Stop): the
    /// running turn and every subagent at work or queued stop; the answer
    /// names them for the undo toast's list and its Restart.
    pub(super) fn stop_all(&mut self) -> Value {
        let turn = self.owner_stop()["stopped"].as_bool().unwrap_or(false);
        let StopPick {
            stopped,
            starting,
            errors,
        } = self.stop_subagents_where(|_| true);
        if !stopped.is_empty() {
            (self.log)(&format!(
                "the owner stopped all agents: {}",
                stopped.join(", ")
            ));
            self.save();
        }
        // A cancel acpmux refused stopped nothing: that one is in `errors`,
        // never in `subagents` (so Restart never touches it).
        let mut answer = json!({"stopped": turn, "subagents": stopped, "errors": errors});
        if let Some(note) = starting_note(&starting) {
            answer["note"] = json!(note);
        }
        answer
    }

    /// chief.stop {restart: [ids]}: Restart on the stop-all toast. A started
    /// one goes on in its own session (control restart: told to continue);
    /// one stopped before it started is queued again with its task.
    pub(super) fn restart_subagents(&mut self, names: &[String]) -> Value {
        let mut restarted = Vec::new();
        let mut errors = Vec::new();
        for name in names {
            let Some(sub) = self.state.sub(name).map(|(_, s)| s.clone()) else {
                errors.push(format!("no subagent {name}"));
                continue;
            };
            // Only one the user stopped: a second Restart, or one already
            // back at work, is left as it is.
            if !sub.cancelled {
                errors.push(format!("{name} is not stopped"));
                continue;
            }
            let still_starting = (sub.status == SubStatus::Starting && sub.session_id.is_none())
                || (sub.session_id.is_some() && sub.awaiting_task);
            let result = match (sub.status, sub.session_id.is_some()) {
                // Stopped while it was starting (no session, or its task not
                // sent yet): it just goes on as it starts. Queued again it
                // would start twice; a cancel now would cut its task turn.
                _ if still_starting => {
                    if let Some(s) = self.state.sub_mut(name) {
                        s.cancelled = false;
                        s.paused = false;
                    }
                    Ok(format!("outcome: done. {name} goes on as it starts"))
                }
                // Its cancelled turn has not ended yet: the message waits
                // for that end (after_stop), never steered into a turn
                // that is ending.
                (SubStatus::Starting | SubStatus::Running, true) => {
                    if let Some(s) = self.state.sub_mut(name) {
                        s.cancelled = false;
                        s.paused = false;
                        s.resume_attempts = 0;
                    }
                    self.control_interrupt(&sub, Some(super::control::RESTART_PROMPT))
                }
                (_, true) => self.control_restart(&sub, None),
                (_, false) => self.queue_again(&sub),
            };
            match result {
                Ok(text) if !text.starts_with("outcome: refused") => restarted.push(name.clone()),
                // Not restarted (acpmux refused the cancel that ends its
                // stopped turn, say): it stays stopped as it was, so a
                // later Restart still brings it back.
                Ok(text) | Err(text) => {
                    if let Some(s) = self.state.sub_mut(name) {
                        s.cancelled = sub.cancelled;
                        s.paused = sub.paused;
                        s.resume_attempts = sub.resume_attempts;
                    }
                    errors.push(format!("{name}: {text}"));
                }
            }
        }
        if !restarted.is_empty() {
            (self.log)(&format!("the owner restarted {}", restarted.join(", ")));
        }
        self.save();
        self.start_queued();
        json!({"restarted": restarted, "errors": errors})
    }

    /// Subagent `sub`, stopped before it started, queued again with its
    /// task.
    fn queue_again(&mut self, sub: &SubRecord) -> Result<String, String> {
        let launch = sub
            .queued_launch
            .clone()
            .unwrap_or_else(|| crate::state::QueuedLaunch {
                task: sub.task.clone(),
                cwd: None,
                effort: None,
                floor: sub.policy.clone(),
                harness: None,
            });
        let s = self
            .state
            .sub_mut(&sub.id)
            .ok_or_else(|| format!("no subagent {}", sub.id))?;
        s.status = SubStatus::Queued;
        s.queued_launch = Some(launch);
        s.cancelled = false;
        s.paused = false;
        s.stopped = false;
        s.report = None;
        Ok(format!("outcome: done. {} is queued again", sub.id))
    }

    /// A background shell (Claude Code's run_in_background) outlives the
    /// turn that started it: a stop or cancel of the subagent ends it too.
    pub(super) fn end_background_processes(&self, id: &str, session: &str) {
        match self.agents.kill_processes(session) {
            Ok(0) => {}
            Ok(n) => (self.log)(&format!("subagent {id}: ended {n} background process(es)")),
            Err(e) => (self.log)(&format!(
                "subagent {id}: ending its background processes: {e}"
            )),
        }
    }

    /// Stops the subagents at work (or queued) whose id `pick` takes.
    fn stop_subagents_where(&mut self, pick: impl Fn(&str) -> bool) -> StopPick {
        let subs: Vec<(String, SubStatus, Option<String>)> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| {
                pick(&s.id)
                    && matches!(
                        s.status,
                        SubStatus::Starting | SubStatus::Running | SubStatus::Queued
                    )
            })
            .map(|s| (s.id.clone(), s.status, s.session_id.clone()))
            .collect();
        // Nothing a picked one was told is sent after the stop (kept aside:
        // a refused cancel gives it back), and each picked queued one is
        // cancelled before any stops: a slot one frees never starts another
        // picked one.
        let mut told = std::collections::HashMap::new();
        for (id, status, _) in &subs {
            if let Some(s) = self.state.sub_mut(id) {
                told.insert(
                    id.clone(),
                    (s.after_stop.take(), std::mem::take(&mut s.inbox)),
                );
                if *status == SubStatus::Queued {
                    s.cancelled = true;
                }
            }
        }
        let mut stopped = Vec::new();
        let mut starting = Vec::new();
        let mut errors = Vec::new();
        for (id, status, session) in subs {
            match (status, session) {
                (SubStatus::Queued, _) => {
                    self.sub_done(
                        &id,
                        "(stopped by the user before it started)".into(),
                        true,
                        None,
                        None,
                    );
                }
                (_, Some(session)) => {
                    // Its task is not sent yet: the cancel may land before
                    // its turn does, so it is stopped again as it starts
                    // (best effort, `stop_if_cancelled`).
                    if self.state.sub(&id).is_some_and(|(_, s)| s.awaiting_task) {
                        starting.push(id.clone());
                    }
                    if let Err(e) = self.agents.cancel(&session) {
                        (self.log)(&format!("subagent {id}: stopping it: {e}"));
                        // Not stopped: it stays as it was.
                        if let Some(s) = self.state.sub_mut(&id)
                            && let Some((after_stop, inbox)) = told.remove(&id)
                        {
                            s.after_stop = after_stop;
                            s.inbox = inbox;
                        }
                        starting.retain(|s| s != &id);
                        errors.push(format!("{id}: its turn did not stop: {e}"));
                        continue;
                    }
                    self.end_background_processes(&id, &session);
                    // Stopped for good: no longer at work, even when its
                    // session never ends the turn (#7).
                    if let Some(s) = self.state.sub_mut(&id) {
                        s.cancelled = true;
                    }
                }
                // Its session is not made yet: cancelled now, so its turn
                // is cancelled as soon as it starts (`stop_if_cancelled`).
                (_, None) => {
                    if let Some(s) = self.state.sub_mut(&id) {
                        s.cancelled = true;
                    }
                    starting.push(id.clone());
                }
            }
            stopped.push(id);
        }
        stopped.sort_by_key(|id| id_order(id));
        starting.sort_by_key(|id| id_order(id));
        StopPick {
            stopped,
            starting,
            errors,
        }
    }

    /// Subagent `id`'s task turn started at acpmux. One cancelled while it
    /// was starting is cancelled again now: the cancel sent as its prompt
    /// went out (`SubagentPrompted`) is lost when it reached acpmux before
    /// the prompt did. Only its task prompt's turn comes here, and only
    /// while it is still cancelled: a Restart in between lets it run.
    pub(super) fn sub_turn_started(&mut self, id: &str, prompt_id: &str) {
        self.trace.emit(
            "subagent.turn_started",
            json!({"id": id, "prompt": prompt_id}),
        );
        self.stop_if_cancelled(id);
    }

    /// A subagent cancelled while it was starting has its first prompt
    /// sent, or its task turn started (`sub_turn_started`): its turn is
    /// cancelled now. A cancel acpmux refuses leaves it at work, and the
    /// Chief is told: the stop's answer already went out saying it stopped.
    pub(super) fn stop_if_cancelled(&mut self, id: &str) {
        let Some(session) = self
            .state
            .sub(id)
            .filter(|(_, s)| s.cancelled && s.status == SubStatus::Running)
            .and_then(|(_, s)| s.session_id.clone())
        else {
            return;
        };
        match self.agents.cancel(&session) {
            Ok(()) => {
                self.end_background_processes(id, &session);
                (self.log)(&format!(
                    "subagent {id}: stopped as it started (it was stopped while starting)"
                ));
            }
            // Its turn goes on: it is at work again, not stopped.
            Err(e) => {
                (self.log)(&format!(
                    "subagent {id}: stopping it as it started: {e}; it goes on"
                ));
                if let Some(s) = self.state.sub_mut(id) {
                    s.cancelled = false;
                }
                self.save();
                self.trace
                    .emit("subagent.stop_refused", json!({"id": id, "error": e}));
                self.queue(
                    format!(
                        "[{id}] did not stop: it was stopped while it was starting, and acpmux refused to cancel its turn ({e}). It goes on with its task."
                    ),
                    Source::Note,
                );
            }
        }
    }
}

/// What a stop of several subagents did: the ones it stopped (in id
/// order, the still-starting ones among them), and one line per one whose
/// cancel acpmux refused.
struct StopPick {
    stopped: Vec<String>,
    starting: Vec<String>,
    errors: Vec<String>,
}

/// `a12` sorts after `a2`.
fn id_order(id: &str) -> u64 {
    id.trim_start_matches('a')
        .parse::<u64>()
        .unwrap_or(u64::MAX)
}

/// The answer's note for subagents stopped while still starting.
fn starting_note(starting: &[String]) -> Option<String> {
    match starting {
        [] => None,
        [one] => Some(format!(
            "{one} is still starting; it stops as soon as it starts."
        )),
        many => Some(format!(
            "{} are still starting; they stop as soon as they start.",
            many.join(", ")
        )),
    }
}

#[cfg(test)]
#[allow(clippy::items_after_test_module)] // impl Brain items follow; moving them is the owner's change
mod security_tests {
    use super::report_requires_approval;

    #[test]
    fn only_a_spawn_floor_report_holds_the_next_turn() {
        assert!(report_requires_approval(Some("ask")));
        assert!(!report_requires_approval(None));
        assert!(!report_requires_approval(Some("unknown")));
        assert!(!report_requires_approval(Some("approve-all")));
    }
}

/// What the at-work line adds: their tasks are not finished yet.
const AT_WORK_NOT_DONE: &str = "Their tasks are not done until each reports: never say they are finished, and keep any reply about them to what is under way.";

impl Brain {
    /// `Subagents at work now: a1, a3. ...` when any runs (a turn's line
    /// after the view); None when none does. It also says their work is not
    /// done yet, so a turn never reports a task finished while the subagent
    /// doing it still runs (issue 25577).
    pub(super) fn at_work_line(&self) -> Option<String> {
        let ids: Vec<&str> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| s.at_work())
            .map(|s| s.id.as_str())
            .collect();
        (!ids.is_empty()).then(|| {
            format!(
                "Subagents at work now: {}. {AT_WORK_NOT_DONE}",
                ids.join(", ")
            )
        })
    }

    /// A running subagent spawned under the spawn floor: the floor stays
    /// `ask` while one lives (`spawn_policy`).
    pub(super) fn ask_subagent_live(&self) -> bool {
        self.state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .any(|s| {
                s.policy.as_deref() == Some(crate::approval::ASK)
                    && matches!(s.status, SubStatus::Starting | SubStatus::Running)
            })
    }

    /// A permission request of subagent session `session_id`, when it is
    /// one: an ask subagent's is refused at once (as an ask child's), any
    /// other's reaches the Chief as a note. True when handled.
    pub(super) fn sub_permission(
        &mut self,
        session_id: &str,
        permission_id: &str,
        request: &Value,
    ) -> bool {
        let Some(id) = self.state.sub_by_session(session_id) else {
            return false;
        };
        let ask = self
            .state
            .sub(&id)
            .is_some_and(|(_, s)| s.policy.as_deref() == Some(crate::approval::ASK));
        let summary: SessionSummary = match serde_json::from_value(json!({
            "sessionId": session_id, "name": id, "status": "running",
            "tags": {crate::subagents::SUBAGENT_TAG: id, crate::approval::POLICY_TAG: if ask { crate::approval::ASK } else { "" }},
        })) {
            Ok(s) => s,
            Err(_) => return true,
        };
        if let Some(sub) = self.state.sub_mut(&id) {
            sub.permission = Some(crate::state::PendingPermission {
                id: permission_id.to_owned(),
                request: request.clone(),
            });
        }
        self.save();
        if ask {
            self.child_permission(&summary, permission_id.to_owned(), request.clone());
            return true;
        }
        let shown = self
            .state
            .sub(&id)
            .is_some_and(|(_, s)| Self::approval_shown(s));
        let text = super::control::permission_note(&id, request, shown);
        self.queue(text, Source::Note);
        if !shown {
            // Nobody can allow it: denied once overdue, unless the Chief
            // denies or steers it first.
            self.watch_unanswered(
                crate::approval::Pending {
                    session_id: session_id.to_owned(),
                    permission_id: permission_id.to_owned(),
                    tool: crate::approval::tool_name(request),
                    request: request.clone(),
                    child: Some(id.clone()),
                },
                "the app shows no working approval button for this subagent",
            );
        }
        true
    }

    /// Whether the person's app shows `sub`'s prompt with an Allow button
    /// that works: a local subagent with a workspace (its agent tab draws
    /// the prompt). A cloud subagent's peer refuses an allow from this
    /// Mac's app, and one with no workspace has no tab.
    pub(super) fn approval_shown(sub: &crate::state::SubRecord) -> bool {
        sub.workspace.is_some() && sub.peer.is_none()
    }
}

/// A tell as the subagent's next prompt; its answer goes to the brain.
fn tell_prompt(
    agents: &dyn crate::acpmux::AgentPort,
    session: &str,
    blocks: Vec<Value>,
    prompt_id: &str,
    forward: std::sync::mpsc::Sender<super::Input>,
    sub_id: String,
) -> Result<(), String> {
    let (tx, rx) = std::sync::mpsc::channel();
    agents.start_prompt(session, blocks, prompt_id, tx)?;
    std::thread::spawn(move || {
        while let Ok(signal) = rx.recv() {
            match signal {
                crate::acpmux::TurnSignal::Changed
                | crate::acpmux::TurnSignal::Noted
                | crate::acpmux::TurnSignal::Streamed => {}
                crate::acpmux::TurnSignal::Done(answer) => {
                    let _ = forward.send(super::Input::SubagentAnswer { id: sub_id, answer });
                    return;
                }
                crate::acpmux::TurnSignal::Lost => return,
            }
        }
    });
    Ok(())
}

/// Inbox messages as one prompt, oldest first.
pub(super) fn inbox_text(messages: &[crate::state::InboxMessage]) -> String {
    match messages {
        [one] => one.text.clone(),
        many => many
            .iter()
            .enumerate()
            .map(|(k, m)| format!("Message {} from the Chief:\n{}", k + 1, m.text))
            .collect::<Vec<_>>()
            .join("\n\n"),
    }
}

/// The text of a prompt acpmux recorded (`user_message`).
fn user_text(msg: &serde_json::Map<String, Value>) -> String {
    if let Some(text) = msg.get("text").and_then(Value::as_str) {
        return text.to_owned();
    }
    msg.get("prompt")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

/// The highest `a<N>` any recorded spawn gave, 0 when none did.
pub(crate) fn highest_subagent(spawns: &std::collections::BTreeMap<String, SpawnRecord>) -> u64 {
    spawns
        .values()
        .flat_map(|record| record.subs.iter())
        .filter_map(|sub| sub.id.strip_prefix('a')?.parse::<u64>().ok())
        .max()
        .unwrap_or(0)
}
