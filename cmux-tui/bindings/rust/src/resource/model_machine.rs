use super::super::id::MachineId;
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;

/// Origin of a machine visible to cmux.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MachineOrigin {
    Local,
    Cloud,
    Ssh,
    Server,
}

/// Current lifecycle state of a machine.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MachineStatus {
    Running,
    Connecting,
    Sleeping,
    Stopped,
    Unavailable,
}

/// Non-secret owner platform metadata; missing fields remain unknown.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct MachinePlatform {
    pub os: Option<String>,
    pub arch: Option<String>,
}

/// Catalog snapshot for one machine.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct MachineSnapshot {
    pub id: MachineId,
    pub name: String,
    pub origin: MachineOrigin,
    pub status: MachineStatus,
    pub connectable: bool,
    pub deleted: bool,
    pub recoverable: bool,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
    #[serde(default)]
    pub platform: Option<MachinePlatform>,
    #[serde(default)]
    pub capabilities: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn cmux_next_machine_catalog_sdk_retains_remote_owner_metadata() {
        for (origin, expected) in [
            ("local", MachineOrigin::Local),
            ("cloud", MachineOrigin::Cloud),
            ("ssh", MachineOrigin::Ssh),
            ("server", MachineOrigin::Server),
        ] {
            let value = json!({"id":"machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "name":"server",
                "origin":origin,"status":"running","connectable":true,"deleted":false,"recoverable":false,
                "platform":{"os":"linux","arch":"aarch64"},"capabilities":["terminal","agent_session"]});
            let machine: MachineSnapshot = serde_json::from_value(value).unwrap();
            assert_eq!(machine.origin, expected);
            assert_eq!(machine.platform.unwrap().os.as_deref(), Some("linux"));
            assert_eq!(machine.capabilities, ["terminal", "agent_session"]);
        }
    }

    #[test]
    fn cmux_next_machine_catalog_sdk_preserves_legacy_defaults_and_refuses_bad_metadata() {
        let value = json!({"id":"machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "name":"local",
            "origin":"local","status":"running","connectable":true,"deleted":false,"recoverable":false});
        let legacy: MachineSnapshot = serde_json::from_value(value.clone()).unwrap();
        assert!(legacy.platform.is_none());
        assert!(legacy.capabilities.is_empty());
        for (field, bad) in [
            ("platform", json!({"os":1})),
            ("platform", json!({"path":"/private"})),
            ("capabilities", json!([1])),
        ] {
            let mut malformed = value.clone();
            malformed[field] = bad;
            assert!(serde_json::from_value::<MachineSnapshot>(malformed).is_err());
        }
    }
}
