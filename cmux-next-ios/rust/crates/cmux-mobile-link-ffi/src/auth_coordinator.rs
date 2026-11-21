//! The app's sign-in and session state machine (`cmux-auth-coordinator`, the
//! reducer the Mac app links through cmux-app-ffi) behind a uniffi object,
//! in the phone's own process: the phone runs no daemon to own it.
//!
//! Swift feeds events and runs the effects; this object holds no token, code
//! or password, as the reducer sees none. Events, effects and the snapshot
//! are the JSON of `cmux_auth_coordinator::wire`, the same the Mac app reads,
//! so one Swift client decodes both. Effects queue, so an answer fed while an
//! earlier effect runs still leaves every effect to run once, in order: drain
//! with `take_effects` until it answers `[]`.
//!
//! The reducer sits behind a mutex held only for the call, so any thread may
//! call it.

use std::sync::{Mutex, MutexGuard, PoisonError};

use cmux_auth_coordinator::wire::Session;

use crate::CmuxMobileError;

/// One app's auth coordinator.
#[derive(uniffi::Object)]
pub struct AuthCoordinator {
    session: Mutex<Session>,
}

impl AuthCoordinator {
    fn session(&self) -> MutexGuard<'_, Session> {
        self.session.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

fn utf8(json: Vec<u8>) -> String {
    // serde_json writes UTF-8.
    String::from_utf8(json).unwrap_or_else(|_| "null".to_owned())
}

#[uniffi::export]
impl AuthCoordinator {
    /// Builds and primes the coordinator from `config_json`
    /// (`{launch?, persisted?, jitterSeed?}`; an empty string means `{}`).
    /// The priming effects wait for `take_effects`.
    #[uniffi::constructor]
    pub fn new(config_json: String) -> Result<Self, CmuxMobileError> {
        let session = Session::from_json(config_json.as_bytes())
            .map_err(|error| CmuxMobileError::InvalidArgument { message: error.to_string() })?;
        Ok(Self { session: Mutex::new(session) })
    }

    /// Applies one event (JSON) and queues its effects. A refused event
    /// changes nothing.
    pub fn feed(&self, event_json: String) -> Result<(), CmuxMobileError> {
        self.session()
            .feed_json(event_json.as_bytes())
            .map_err(|error| CmuxMobileError::InvalidArgument { message: error.to_string() })
    }

    /// The queued effects as a JSON array, oldest first (`[]` when none);
    /// the queue is left empty.
    pub fn take_effects(&self) -> String {
        utf8(self.session().take_effects_json())
    }

    /// What the coordinator publishes now, as a JSON object.
    pub fn snapshot(&self) -> String {
        utf8(self.session().snapshot_json())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn effects(coordinator: &AuthCoordinator) -> Vec<Value> {
        match serde_json::from_str(&coordinator.take_effects()).unwrap() {
            Value::Array(items) => items,
            other => panic!("not an array: {other}"),
        }
    }

    /// The phone's launch restore asks for the token probe, and the probe's
    /// answer (no stored tokens) leaves it signed out.
    #[test]
    fn a_launch_with_no_tokens_restores_to_signed_out() {
        let coordinator = AuthCoordinator::new(String::new()).unwrap();
        effects(&coordinator);
        coordinator.feed(json!({"restore": "launch"}).to_string()).unwrap();
        let fx = effects(&coordinator);
        let ticket = fx
            .iter()
            .find_map(|effect| effect.get("probeStoredTokens"))
            .expect("the restore probes the stored tokens")
            .clone();
        coordinator
            .feed(
                json!({"tokensProbed": {
                    "ticket": ticket,
                    "probe": {"Ok": false},
                    "storageWasAvailable": true,
                    "readFailed": false,
                }})
                .to_string(),
            )
            .unwrap();
        assert!(effects(&coordinator).contains(&json!("restoreFinished")));
        let snapshot: Value = serde_json::from_str(&coordinator.snapshot()).unwrap();
        assert_eq!(snapshot["isAuthenticated"], json!(false));
        assert_eq!(snapshot["isRestoringSession"], json!(false));
        assert_eq!(effects(&coordinator), Vec::<Value>::new());
    }

    /// The shell's own requests and the snapshot fields its runners compare
    /// cross the phone's surface as JSON too.
    #[test]
    fn the_shell_requests_and_their_snapshot_fields_cross_as_json() {
        let coordinator = AuthCoordinator::new(String::new()).unwrap();
        effects(&coordinator);
        let snapshot: Value = serde_json::from_str(&coordinator.snapshot()).unwrap();
        assert_eq!(snapshot["tokenStoreWriteHighWater"], json!(0));
        assert_eq!(snapshot["hasActiveSignInFlows"], json!(false));
        coordinator
            .feed(json!({"availableTeamsSet": [{"id": "t1", "displayName": "One"}]}).to_string())
            .unwrap();
        let snapshot: Value = serde_json::from_str(&coordinator.snapshot()).unwrap();
        assert_eq!(snapshot["availableTeams"][0]["id"], json!("t1"));
        coordinator
            .feed(
                json!({"clearAuthStateRequested": {"reason": "test", "preservePendingCode": true}})
                    .to_string(),
            )
            .unwrap();
        assert!(effects(&coordinator).contains(&json!({"logSignOut": {"reason": "test"}})));
        let snapshot: Value = serde_json::from_str(&coordinator.snapshot()).unwrap();
        assert_eq!(snapshot["lastSignOutReason"], json!("test"));
        assert_eq!(snapshot["availableTeams"], json!([]));
    }

    #[test]
    fn a_malformed_event_is_refused_and_changes_nothing() {
        let coordinator = AuthCoordinator::new("{}".to_owned()).unwrap();
        let before = coordinator.snapshot();
        let error = coordinator.feed("{\"restore\": \"secret@example.com\"}".to_owned()).unwrap_err();
        assert!(matches!(error, CmuxMobileError::InvalidArgument { .. }));
        assert!(!error.to_string().contains("secret"), "the error names no value: {error}");
        assert_eq!(coordinator.snapshot(), before);
        assert!(AuthCoordinator::new("[".to_owned()).is_err());
    }
}
