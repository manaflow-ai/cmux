//! `ChildAgent`: recovering a lost host and handling the host's own entries.

use super::*;

impl ChildAgent {
    /// The agent holder (`agent_host/custody.rs`): when this agent's host died while its harness
    /// runs and this daemon holds custody of it, start a replacement host on the harness's stdio
    /// and reattach to it, keeping every open request and the turn. True when the current link
    /// is good after it (replaced here, or by another caller meanwhile); false when the host is
    /// not dead, there is no custody, the harness ended, or the replacement failed: the caller
    /// goes on as without the holder.
    #[cfg(unix)]
    pub async fn recover_host(self: &Arc<Self>) -> bool {
        let Some(h) = &self.hosted else { return false };
        if !crate::agent_host::custody::holder_on() {
            return false;
        }
        let _turn = h.reattach_turn.lock().await;
        let link = h.link();
        let lost =
            link.is_closed() || h.broken.load(Ordering::SeqCst) || h.stopped.load(Ordering::SeqCst);
        let custody = h.custody.lock_or_recover().clone();
        let Some(custody) = custody else { return !lost && !link.is_closed() };
        if custody.record.start_nonce != link.record.start_nonce {
            // Custody of an earlier host: the link was replaced meanwhile.
            return !lost;
        }
        if h.detached.load(Ordering::SeqCst) || h.exit_seen.load(Ordering::SeqCst) {
            return false;
        }
        // Its socket may close a moment before its live lock frees: a short bounded wait, as
        // `hub/hosts.rs` `readopt` waits. A host that lives on is reached as a lost link instead.
        let dead = crate::agent_host::host_dead_now(&link.record)
            || crate::agent_host::wait_dead_async(
                custody.spec.hosts_dir.clone(),
                link.record.session_id.clone(),
                link.record.start_nonce.clone(),
                std::time::Duration::from_millis(500),
            )
            .await;
        if !dead {
            return false;
        }
        if !custody.harness_alive() {
            return false;
        }
        let started = std::time::Instant::now();
        let last_h = *h.logged.borrow();
        let replay_from = h.logged_o.load(Ordering::SeqCst);
        let max_out_id = self.next_id.load(Ordering::SeqCst).saturating_sub(1);
        let launcher = match crate::agent_host::link::HostLauncher::current() {
            Ok(l) => l,
            Err(e) => {
                tracing::warn!(agent = %self.name, "agent holder: no launcher: {e:#}");
                return false;
            }
        };
        let record = match crate::agent_host::custody::respawn(
            &launcher,
            &custody,
            last_h,
            max_out_id,
            replay_from,
        )
        .await
        {
            Ok(record) => record,
            Err(e) => {
                tracing::warn!(agent = %self.name, "agent holder: no replacement host: {e:#}");
                return false;
            }
        };
        // The dead host's lock file; its record and socket are the replacement's now.
        crate::agent_host::remove_own_artifacts(&custody.spec.hosts_dir, &custody.record);
        *h.custody.lock_or_recover() = None;
        if let Err(e) = self.reattach_to(h, record).await {
            tracing::warn!(agent = %self.name, "agent holder: replacement host not reached: {e:#}");
            return false;
        }
        tracing::warn!(
            agent = %self.name,
            ms = started.elapsed().as_millis() as u64,
            "agent holder: its host died; a replacement host took over the running harness"
        );
        true
    }

    /// The open requests of a link whose reader stopped while its host lived fail once that host is
    /// proven gone ([`crate::agent_host::link::host_ended`]), or at once when its live lock can not
    /// be watched (no proof keeps them open), unless a reattach or a detach took them first.
    pub(super) async fn fail_pending_once_host_ends(
        &self,
        link: &Arc<crate::agent_host::link::Link>,
    ) {
        let Some(hosted) = &self.hosted else { return };
        let _ = crate::agent_host::link::host_ended(&link.record).await;
        let mut p = self.pending.lock().await;
        if hosted.detached.load(Ordering::SeqCst) || !Arc::ptr_eq(&hosted.link(), link) {
            return;
        }
        for (_, tx) in p.map.drain() {
            let _ = tx.send(Err(RpcError::internal(AGENT_CLOSED)));
        }
    }

    /// Log one host entry, then act on it. Returns whether its record was
    /// stored (only then may it be acknowledged).
    pub(super) async fn on_host_entry(
        &self,
        h: u64,
        entry: crate::agent_host::Entry,
        inbound: &mpsc::Sender<Inbound>,
    ) -> bool {
        use crate::agent_host::{Entry, TapDir};
        // Debug builds only: `ACPMUX_TEST_UNLOGGED_ONCE=TEXT` fails to log the first host entry
        // whose text holds TEXT, once per process, as a full disk does: the link breaks and the
        // entry stays with the host for the next attach. Release builds have no seam.
        #[cfg(debug_assertions)]
        if let Ok(text) = std::env::var("ACPMUX_TEST_UNLOGGED_ONCE") {
            static FIRED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
            let msg = match &entry {
                Entry::Tap { msg, .. } | Entry::In { msg } => Some(msg.to_string()),
                _ => None,
            };
            if msg.is_some_and(|m| m.contains(&text)) && !FIRED.swap(true, Ordering::SeqCst) {
                return false;
            }
        }
        match entry {
            Entry::Tap { dir, msg } => match Message::from_value(msg) {
                Ok(m) => {
                    let d = if dir == TapDir::In { Direction::In } else { Direction::Out };
                    if let (Direction::Out, Message::Response { id, .. }, Some(hosted)) =
                        (d, &m, &self.hosted)
                    {
                        // The host took this answer: it is never sent again.
                        hosted.unlogged_answers.lock_or_recover().retain(|a| a.id != key(id));
                    }
                    (self.tap)(d, &m, Some(h))
                }
                Err(_) => true,
            },
            Entry::In { msg } => {
                let Ok(m) = Message::from_value(msg) else { return true };
                let host_incarnation =
                    self.hosted.as_ref().map(|host| host.link().record.incarnation.clone());
                let needs_durable_cancel = matches!(
                    &m,
                    Message::Notification { method, params }
                        if method == crate::rpc::method::CANCEL_REQUEST
                            && params.as_ref().and_then(|p| p.get("requestId")).is_some()
                );
                // The incarnation-bearing marker is this entry's durable
                // checkpoint. Store it before acknowledging the cancellation.
                if needs_durable_cancel {
                    let Message::Notification { method, params } = &m else { return false };
                    let (done, persisted) = oneshot::channel();
                    if inbound
                        .send(Inbound::Notification {
                            method: method.clone(),
                            params: params.clone(),
                            host_seq: Some(h),
                            host_incarnation: host_incarnation.clone(),
                            persisted: Some(done),
                            agent: self.generation,
                        })
                        .await
                        .is_err()
                    {
                        return false;
                    }
                    if !persisted.await.unwrap_or(false) {
                        return false;
                    }
                }
                // The incarnation-bearing durable marker owns a cancellation's
                // checkpoint. Its delayed raw copy must never advance a new host.
                let raw_seq = (!needs_durable_cancel).then_some(h);
                match self.tap_live(&m, || (self.tap)(Direction::In, &m, raw_seq)) {
                    None => return true,
                    Some(false) => return false,
                    Some(true) => {}
                }
                match m {
                    Message::Response { id, result, error } => {
                        let answer = match error {
                            Some(e) => Err(e),
                            None => Ok(result.unwrap_or(Value::Null)),
                        };
                        let mut p = self.pending.lock().await;
                        if let Some(tx) = p.map.remove(&key(&id)) {
                            let _ = tx.send(answer);
                        } else if !p.cancelled.take_late(&key(&id), "agent host") {
                            if p.orphans.len() >= ORPHAN_ANSWERS {
                                p.orphans.pop_front();
                            }
                            p.orphans.push_back((key(&id), answer));
                        }
                    }
                    Message::Request { id, method, params } => {
                        let _ = inbound
                            .send(Inbound::Request {
                                id,
                                method,
                                params,
                                host_seq: Some(h),
                                host_incarnation,
                            })
                            .await;
                    }
                    Message::Notification { method, params } => {
                        if needs_durable_cancel {
                            return true;
                        }
                        let _ = inbound
                            .send(Inbound::Notification {
                                method,
                                params,
                                host_seq: Some(h),
                                host_incarnation: host_incarnation.clone(),
                                persisted: None,
                                agent: self.generation,
                            })
                            .await;
                    }
                }
                true
            }
            Entry::Err { line } => {
                let note = Message::notification(HOST_STDERR, serde_json::json!({"text": line}));
                if !(self.tap)(Direction::In, &note, Some(h)) {
                    return false;
                }
                let _ = inbound
                    .send(Inbound::Stderr(
                        line,
                        Some(h),
                        Some((self.generation, StderrPipe::Stderr)),
                    ))
                    .await;
                true
            }
            Entry::Exit { code } => {
                let note = Message::notification(HOST_EXIT, serde_json::json!({"code": code}));
                if !(self.tap)(Direction::In, &note, Some(h)) {
                    return false;
                }
                // Not alive from here: no turn may set the session ready on
                // a harness that is gone while the ack is still being written.
                // What its host had for it is never written now (its link settled it).
                if let Some(hosted) = &self.hosted {
                    hosted.exit_seen.store(true, Ordering::SeqCst);
                }
                let mut p = self.pending.lock().await;
                for (_, tx) in p.map.drain() {
                    let _ = tx.send(Err(RpcError::internal(AGENT_CLOSED)));
                }
                drop(p);
                // `exited` and the exit notify follow the Exit entry's ack
                // (`start_reader`), so a terminate that waits on them never
                // returns before the host knows its Exit is logged.
                let _ =
                    inbound.send(Inbound::Exited { pid: self.pid, code, host_seq: Some(h) }).await;
                true
            }
        }
    }
}
