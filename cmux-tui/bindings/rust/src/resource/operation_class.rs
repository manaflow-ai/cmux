//! The class of each resource operation (read, mutation, stream open,
//! connection control), which decides its idempotency policy and transport.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum OperationClass {
    Read,
    Mutation,
    StreamOpen,
    ConnectionControl,
}

pub(crate) fn operation_class(operation: &str) -> OperationClass {
    use super::ops;

    if matches!(
        operation,
        ops::SESSION_EVENTS
            | ops::SESSION_JOURNAL_SUBSCRIBE
            | ops::TERMINAL_ATTACH
            | ops::BROWSER_ATTACH
            | ops::SIDEBAR_VIEW_ATTACH
    ) {
        OperationClass::StreamOpen
    } else if matches!(
        operation,
        ops::REQUEST_CANCEL
            | ops::STREAM_CANCEL
            | ops::CLIENT_METADATA_UPDATE
            | ops::CLIENT_SIZING_SET
            | ops::CLIENT_SIZING_RELEASE
            | ops::CLIENT_CELL_PIXELS_SET
            | ops::CLIENT_DETACH
            | ops::TERMINAL_VIEWER_RESIZE
            | ops::TERMINAL_VIEWER_RELEASE
            | ops::BROWSER_VIEWER_RESIZE
            | ops::BROWSER_VIEWER_RELEASE
            | ops::TERMINAL_RENDERER_GRANT_CREATE
    ) {
        OperationClass::ConnectionControl
    } else if matches!(
        operation,
        ops::MACHINE_LIST
            | ops::MACHINE_GET
            | ops::SESSION_LIST
            | ops::SESSION_GET
            | ops::SESSION_CREATION_RESOLVE
            | ops::SESSION_SNAPSHOT
            | ops::SESSION_JOURNAL_PRODUCER_LIST
            | ops::SESSION_PING
            | ops::CLIENT_LIST
            | ops::CLIENT_GET
            | ops::PAIRING_REQUEST_LIST
            | ops::FRONTEND_PROJECTION_GET
            | ops::WORKSPACE_LIST
            | ops::WORKSPACE_GET
            | ops::SCREEN_LIST
            | ops::SCREEN_GET
            | ops::SCREEN_LAYOUT_EXPORT
            | ops::PANE_LIST
            | ops::PANE_GET
            | ops::PANE_NEIGHBOR_GET
            | ops::TAB_LIST
            | ops::TAB_GET
            | ops::TERMINAL_LIST
            | ops::TERMINAL_GET
            | ops::TERMINAL_SCREEN_READ
            | ops::TERMINAL_STATE_READ
            | ops::TERMINAL_HISTORY_READ
            | ops::TERMINAL_WAIT
            | ops::TERMINAL_WAIT_EXIT
            | ops::TERMINAL_COPY
            | ops::TERMINAL_PROCESS_GET
            | ops::BROWSER_LIST
            | ops::BROWSER_GET
            | ops::NOTIFICATION_LIST
            | ops::AGENT_LIST
            | ops::SIDEBAR_VIEW_GET
            | ops::WINDOW_RECORD_LIST
            | ops::WORKSPACE_GROUP_LIST
            | ops::WORKSPACE_PLACEMENT_LIST
            | ops::CLOSED_LIST
            | ops::TAB_GROUP_LIST
            | ops::TAB_GROUP_GET
            | ops::SAVED_TAB_GROUP_LIST
    ) {
        OperationClass::Read
    } else {
        OperationClass::Mutation
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every operation the SDK sends has the class the catalog declares.
    #[test]
    fn every_sdk_operation_has_its_catalog_class() {
        let catalog: serde_json::Value =
            serde_json::from_str(include_str!("../../../../spec/resource-operations-v2.json"))
                .unwrap();
        let names = include_str!("ops.rs")
            .lines()
            .filter(|line| line.trim_start().starts_with("pub(crate) const "))
            .filter_map(|line| line.split('"').nth(1))
            .collect::<Vec<_>>();
        assert!(!names.is_empty());
        for name in names {
            let expected = match catalog["operations"][name]["class"].as_str() {
                Some("read") => OperationClass::Read,
                Some("mutation") => OperationClass::Mutation,
                Some("stream_open") => OperationClass::StreamOpen,
                Some("connection_control") => OperationClass::ConnectionControl,
                other => panic!("{name} has catalog class {other:?}"),
            };
            assert_eq!(operation_class(name), expected, "{name}");
        }
    }
}
