//! A moved Chief reaches the subagents it handed over (migrate_subagents.rs).
//!
//! A Chief that moves to another machine takes its working subagents with it:
//! `acpmux session move ... --machine PEER` lands each chat on that machine's
//! default acpmux daemon (`~/.acpmux`), not on the Chief home's own daemon
//! (`<home>/acpmux`), and the move records the chat's new `place` on its
//! subagent record. On that machine the Chief's host links to both daemons:
//! [`PlacedPort`] sends every call about a placed session to the machine's
//! daemon and the rest to the home's, and folds the machine daemon's events
//! into the home link's, so the brain sees one acpmux. Without it, the moved
//! Chief's first link listed no such session and reported each handed-over
//! subagent gone.

use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc::Sender;

use cmux_chief::acp::{AcpmuxEvent, SessionSummary};
use serde_json::Value;

use crate::acpmux::{AgentEvent, AgentPort, SessionSpec, SteerWait, TurnSignal};

/// The sessions of the home's subagent records that carry a `place`: the
/// chats a move handed over to this machine's default acpmux daemon. Read from
/// the home's host state (`host/spawns` in `optchat/memory.sqlite3`); a home
/// with none (or no state yet) has none.
pub fn placed_sessions(home: &Path) -> HashSet<String> {
    let db = home.join("optchat/memory.sqlite3");
    if !db.is_file() {
        return HashSet::new();
    }
    let key = format!("{}spawns", crate::state::HOST_PREFIX);
    let text: Option<String> =
        rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .ok()
            .and_then(|c| {
                c.query_row("SELECT value FROM state WHERE key = ?1", [&key], |r| {
                    r.get(0)
                })
                .ok()
            });
    text.and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .map(|spawns| placed_in(&spawns))
        .unwrap_or_default()
}

/// This machine's default acpmux daemon's socket (`~/.acpmux/acpmux.sock`,
/// whatever `ACPMUX_HOME` the Chief's own daemon has): where `acpmux session
/// move --machine` lands a chat.
pub fn machine_socket() -> std::path::PathBuf {
    let user = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| "/".into());
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    crate::acpmux_daemon::socket_path_for(None, None, &user, uid)
}

/// [`placed_sessions`] of `host/spawns`'s JSON.
fn placed_in(spawns: &Value) -> HashSet<String> {
    spawns
        .as_object()
        .into_iter()
        .flat_map(|m| m.values())
        .filter_map(|r| r["subs"].as_array())
        .flatten()
        .filter(|s| s["place"].as_str().is_some_and(|p| !p.is_empty()))
        .filter_map(|s| s["session_id"].as_str().map(str::to_owned))
        .collect()
}

/// A closed summary of session `id`, for one the machine daemon lacks.
fn closed(id: &str) -> SessionSummary {
    SessionSummary {
        session_id: id.into(),
        name: String::new(),
        harness: String::new(),
        cwd: String::new(),
        status: cmux_chief::acp::SessionStatus::Closed,
        pending_permissions: 0,
        state_seq: 0,
        last_seq: None,
        turn_count: None,
        preview: None,
        last_prompt: None,
        last_message: None,
        tags: Default::default(),
    }
}

/// The Chief's acpmux port on a machine it moved to: the home daemon's port,
/// with the placed sessions' calls on the machine daemon's port.
pub struct PlacedPort {
    home: Arc<dyn AgentPort>,
    here: Arc<dyn AgentPort>,
    placed: HashSet<String>,
}

impl PlacedPort {
    /// `home`: the Chief home's own daemon; `here`: this machine's default
    /// daemon; `placed`: the sessions on `here` ([`placed_sessions`]). The set
    /// is fixed for the host's life: only a move places a session, and a move
    /// runs while the host is stopped.
    pub fn new(
        home: Arc<dyn AgentPort>,
        here: Arc<dyn AgentPort>,
        placed: HashSet<String>,
    ) -> Arc<PlacedPort> {
        Arc::new(PlacedPort { home, here, placed })
    }

    /// The sessions a move placed on this machine's daemon.
    pub fn placed(&self) -> &HashSet<String> {
        &self.placed
    }

    fn port(&self, session: &str) -> &dyn AgentPort {
        if self.placed.contains(session) {
            &*self.here
        } else {
            &*self.home
        }
    }

    /// The home link's event as the brain gets it: its session list with
    /// each placed session the machine daemon has added, so a reconnect
    /// never takes a handed-over subagent for gone.
    pub fn home_event(&self, event: AgentEvent) -> AgentEvent {
        let AgentEvent::Up(mut list) = event else {
            return event;
        };
        let mut missing: Vec<&String> = self
            .placed
            .iter()
            .filter(|id| !list.iter().any(|s| &s.session_id == *id))
            .collect();
        missing.sort();
        for id in missing {
            // A machine daemon that does not answer now: its own link's list
            // brings the session when it does.
            if let Ok(Some(summary)) = self.here.session(id) {
                list.push(summary);
            }
        }
        AgentEvent::Up(list)
    }

    /// The machine link's events as the brain gets them: only those about a
    /// placed session. Its list is each placed session's change (closed for
    /// one it lacks); its link
    /// going down or ending is not the Chief's (the home link's is).
    pub fn here_events(&self, event: AgentEvent) -> Vec<AgentEvent> {
        match event {
            AgentEvent::Up(list) => {
                let mut gone: Vec<&String> = self
                    .placed
                    .iter()
                    .filter(|id| !list.iter().any(|s| &s.session_id == *id))
                    .collect();
                gone.sort();
                // A placed session the machine daemon lacks has ended: the
                // home list no longer judges it (Brain::set_reported_elsewhere).
                let gone: Vec<AgentEvent> = gone
                    .into_iter()
                    .map(|id| AgentEvent::SessionChanged(closed(id)))
                    .collect();
                list.into_iter()
                    .filter(|s| self.placed.contains(&s.session_id))
                    .map(AgentEvent::SessionChanged)
                    .chain(gone)
                    .collect()
            }
            AgentEvent::SessionChanged(s) if self.placed.contains(&s.session_id) => {
                vec![AgentEvent::SessionChanged(s)]
            }
            AgentEvent::Permission {
                session_id,
                permission_id,
                request,
            } if self.placed.contains(&session_id) => vec![AgentEvent::Permission {
                session_id,
                permission_id,
                request,
            }],
            _ => Vec::new(),
        }
    }
}

impl AgentPort for PlacedPort {
    fn new_session(&self, spec: &SessionSpec) -> Result<String, String> {
        self.home.new_session(spec)
    }
    fn new_plain_session(&self, spec: &SessionSpec) -> Result<String, String> {
        self.home.new_plain_session(spec)
    }
    fn start_prompt(
        &self,
        session: &str,
        blocks: Vec<Value>,
        prompt_id: &str,
        signals: Sender<TurnSignal>,
    ) -> Result<(), String> {
        self.port(session)
            .start_prompt(session, blocks, prompt_id, signals)
    }
    fn events(&self, session: &str, after: u64) -> Result<Vec<AcpmuxEvent>, String> {
        self.port(session).events(session, after)
    }
    fn end_session(&self, session: &str) -> Result<(), String> {
        self.port(session).end_session(session)
    }
    fn find(&self, name: &str) -> Result<Option<String>, String> {
        self.home.find(name)
    }
    fn session(&self, id: &str) -> Result<Option<SessionSummary>, String> {
        self.port(id).session(id)
    }
    fn cancel(&self, session: &str) -> Result<(), String> {
        self.port(session).cancel(session)
    }
    fn kill_processes(&self, session: &str) -> Result<usize, String> {
        self.port(session).kill_processes(session)
    }
    fn remove_queued(&self, session: &str, prompt_id: &str) -> Result<bool, String> {
        self.port(session).remove_queued(session, prompt_id)
    }
    fn set_mode(&self, session: &str, mode: &str) -> Result<(), String> {
        self.port(session).set_mode(session, mode)
    }
    fn probe_models(&self, harness: &str) -> Result<(), String> {
        self.home.probe_models(harness)
    }
    fn offered_models(&self, harness: &str) -> Result<Vec<Value>, String> {
        self.home.offered_models(harness)
    }
    fn harness_catalog(&self) -> Result<Value, String> {
        self.home.harness_catalog()
    }
    fn harness_catalog_on(&self, peer: Option<&str>) -> Result<Value, String> {
        self.home.harness_catalog_on(peer)
    }
    fn harness_health_on(&self, peer: Option<&str>) -> Result<Value, String> {
        self.home.harness_health_on(peer)
    }
    fn machine_status(&self) -> Result<Value, String> {
        self.home.machine_status()
    }
    fn respond_permission(
        &self,
        session: &str,
        permission: &str,
        option: Option<&str>,
    ) -> Result<(), String> {
        self.port(session)
            .respond_permission(session, permission, option)
    }
    fn start_steer(
        &self,
        session: &str,
        blocks: Vec<Value>,
        prompt_id: &str,
    ) -> Result<SteerWait, String> {
        self.port(session).start_steer(session, blocks, prompt_id)
    }
    fn start_steer_now(
        &self,
        session: &str,
        blocks: Vec<Value>,
        prompt_id: &str,
    ) -> Result<SteerWait, String> {
        self.port(session)
            .start_steer_now(session, blocks, prompt_id)
    }
    fn trust_folder(&self, cwd: &Path) -> Result<(), String> {
        self.home.trust_folder(cwd)
    }
    fn prewarm(&self, harness: &str, preset: Option<&str>, cwd: &Path) -> Result<(), String> {
        self.home.prewarm(harness, preset, cwd)
    }
    fn preset_installed(&self, preset: &str) -> Option<bool> {
        self.home.preset_installed(preset)
    }
    fn refresh_preset(&self, preset: &str) -> Vec<String> {
        self.home.refresh_preset(preset)
    }
    fn preset_args(&self, preset: &str) -> bool {
        self.home.preset_args(preset)
    }
    fn system_prompt(&self, preset: &str) -> bool {
        self.home.system_prompt(preset)
    }
    fn set_system_prompt(&self, preset: &str, text: &str) -> Result<(), String> {
        self.home.set_system_prompt(preset, text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_chief::acp::SessionStatus;
    use serde_json::json;
    use std::sync::Mutex;

    /// A daemon that answers for its own sessions and records each call.
    struct Daemon {
        name: &'static str,
        sessions: Vec<&'static str>,
        calls: Mutex<Vec<String>>,
    }

    impl Daemon {
        fn new(name: &'static str, sessions: Vec<&'static str>) -> Arc<Daemon> {
            Arc::new(Daemon {
                name,
                sessions,
                calls: Mutex::new(Vec::new()),
            })
        }
        fn called(&self, what: &str, session: &str) -> Result<(), String> {
            self.calls.lock().unwrap().push(format!("{what} {session}"));
            if self.sessions.contains(&session) {
                Ok(())
            } else {
                Err(format!("{}: no session {session}", self.name))
            }
        }
        fn calls(&self) -> Vec<String> {
            self.calls.lock().unwrap().clone()
        }
    }

    fn summary(id: &str) -> SessionSummary {
        SessionSummary {
            session_id: id.into(),
            name: id.into(),
            harness: "claude".into(),
            cwd: String::new(),
            status: SessionStatus::Running,
            pending_permissions: 0,
            state_seq: 0,
            last_seq: None,
            turn_count: None,
            preview: None,
            last_prompt: None,
            last_message: None,
            tags: Default::default(),
        }
    }

    impl AgentPort for Daemon {
        fn new_session(&self, _: &SessionSpec) -> Result<String, String> {
            self.calls.lock().unwrap().push("new".into());
            Ok(format!("{}-new", self.name))
        }
        fn start_prompt(
            &self,
            session: &str,
            _: Vec<Value>,
            _: &str,
            _: Sender<TurnSignal>,
        ) -> Result<(), String> {
            self.called("prompt", session)
        }
        fn events(&self, session: &str, _: u64) -> Result<Vec<AcpmuxEvent>, String> {
            self.called("events", session).map(|_| Vec::new())
        }
        fn end_session(&self, session: &str) -> Result<(), String> {
            self.called("end", session)
        }
        fn find(&self, _: &str) -> Result<Option<String>, String> {
            Ok(None)
        }
        fn session(&self, id: &str) -> Result<Option<SessionSummary>, String> {
            self.calls.lock().unwrap().push(format!("session {id}"));
            Ok(self.sessions.contains(&id).then(|| summary(id)))
        }
        fn cancel(&self, session: &str) -> Result<(), String> {
            self.called("cancel", session)
        }
        fn start_steer_now(
            &self,
            session: &str,
            _: Vec<Value>,
            _: &str,
        ) -> Result<SteerWait, String> {
            self.called("steer", session)
                .map(|_| Box::new(|| Ok(())) as SteerWait)
        }
        fn respond_permission(
            &self,
            session: &str,
            _: &str,
            _: Option<&str>,
        ) -> Result<(), String> {
            self.called("permission", session)
        }
    }

    /// The laptop Chief's home daemon (its turn `s-chief`) and the mini's
    /// default daemon, which took the working subagent `s-work` in the move.
    fn moved() -> (Arc<Daemon>, Arc<Daemon>, Arc<PlacedPort>) {
        let home = Daemon::new("home", vec!["s-chief", "s-idle"]);
        let here = Daemon::new("here", vec!["s-work", "s-person"]);
        let port = PlacedPort::new(
            home.clone(),
            here.clone(),
            HashSet::from(["s-work".to_owned()]),
        );
        (home, here, port)
    }

    #[test]
    fn a_moved_chief_tells_its_handed_over_subagent_on_this_machines_daemon() {
        let (home, here, port) = moved();
        let (tx, _rx) = std::sync::mpsc::channel();
        port.start_prompt(
            "s-work",
            vec![json!({"type": "text", "text": "go on"})],
            "p1",
            tx,
        )
        .expect("a tell reaches the handed-over subagent");
        port.steer_now("s-work", Vec::new(), "p2")
            .expect("a steer reaches it");
        port.events("s-work", 0).expect("its events are read");
        port.cancel("s-work").expect("it can be stopped");
        port.respond_permission("s-work", "perm", Some("allow"))
            .expect("its permission is answered");
        assert_eq!(
            port.session("s-work").unwrap().map(|s| s.session_id),
            Some("s-work".to_owned())
        );
        // The Chief's own sessions stay on its home daemon.
        let (tx, _rx) = std::sync::mpsc::channel();
        port.start_prompt("s-chief", Vec::new(), "p3", tx).unwrap();
        assert_eq!(
            port.new_session(&SessionSpec::default()).unwrap(),
            "home-new"
        );
        assert_eq!(
            here.calls(),
            [
                "prompt s-work",
                "steer s-work",
                "events s-work",
                "cancel s-work",
                "permission s-work",
                "session s-work"
            ]
        );
        assert_eq!(home.calls(), ["prompt s-chief", "new"]);
    }

    #[test]
    fn the_home_link_keeps_a_handed_over_subagent_alive() {
        let (_, _, port) = moved();
        let AgentEvent::Up(list) = port.home_event(AgentEvent::Up(vec![summary("s-chief")])) else {
            panic!("the home link's list stays a list");
        };
        let ids: Vec<&str> = list.iter().map(|s| s.session_id.as_str()).collect();
        assert_eq!(ids, ["s-chief", "s-work"]);
        // Its other events pass as they are.
        assert!(matches!(
            port.home_event(AgentEvent::Down),
            AgentEvent::Down
        ));
    }

    #[test]
    fn the_machine_daemon_reports_only_the_handed_over_sessions() {
        let (_, _, port) = moved();
        let up = port.here_events(AgentEvent::Up(vec![summary("s-work"), summary("s-person")]));
        assert!(
            matches!(&up[..], [AgentEvent::SessionChanged(s)] if s.session_id == "s-work"),
            "{up:?}"
        );
        assert_eq!(
            port.here_events(AgentEvent::SessionChanged(summary("s-work")))
                .len(),
            1
        );
        assert!(
            port.here_events(AgentEvent::SessionChanged(summary("s-person")))
                .is_empty()
        );
        let asked = port.here_events(AgentEvent::Permission {
            session_id: "s-work".into(),
            permission_id: "perm".into(),
            request: json!({}),
        });
        assert_eq!(asked.len(), 1);
        assert!(port.here_events(AgentEvent::Down).is_empty());
        assert!(port.here_events(AgentEvent::Ended).is_empty());
    }

    #[test]
    fn a_handed_over_session_the_machine_daemon_lacks_is_reported_closed() {
        let (_, _, port) = moved();
        let up = port.here_events(AgentEvent::Up(vec![summary("s-person")]));
        assert!(
            matches!(&up[..], [AgentEvent::SessionChanged(s)]
                if s.session_id == "s-work" && s.status == SessionStatus::Closed),
            "{up:?}"
        );
    }

    #[test]
    fn only_subagents_a_move_placed_are_read_as_placed() {
        let spawns = json!({
            "sp1": {"subs": [
                {"id": "a1", "session_id": "s-work", "status": "running", "place": "mini-peer", "epoch": 1},
                {"id": "a2", "session_id": "s-idle", "status": "done"},
                {"id": "a3", "status": "queued", "place": "mini-peer"}
            ]}
        });
        assert_eq!(placed_in(&spawns), HashSet::from(["s-work".to_owned()]));
    }
}
