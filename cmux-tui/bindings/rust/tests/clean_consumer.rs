//! This integration crate intentionally uses only installed public paths.

use cmux::{
    Browser, Client, Config, Machine, Pane, Screen, Selector, Session, Tab, Terminal, Workspace,
    WorkspaceId,
};

#[test]
fn clean_consumer_imports_high_level_and_raw_namespaces_together() {
    type PublicHandles = (
        Option<Client>,
        Option<Machine>,
        Option<Session>,
        Option<Workspace>,
        Option<Screen>,
        Option<Pane>,
        Option<Tab>,
        Option<Terminal>,
        Option<Browser>,
    );
    fn high_level_types(_: PublicHandles) {}
    fn raw_types(_: cmux::raw::PingRequest, _: Option<cmux::raw::Client>) {}

    let selector = Selector::<WorkspaceId>::name("same name");
    assert_eq!(selector.exact_name(), Some("same name"));
    high_level_types((None, None, None, None, None, None, None, None, None));
    raw_types(cmux::raw::PingRequest::default(), None);
    let _config = Config::from_env_or_default_session("consumer");
}

#[test]
fn newly_cataloged_raw_commands_are_public() {
    let _: fn(
        &mut cmux::raw::Client,
        cmux::raw::ClearHistoryRequest,
    ) -> cmux::raw::Result<cmux::raw::ClearHistoryResult> = cmux::raw::Client::clear_history;
    let _: fn(
        &mut cmux::raw::Client,
        cmux::raw::NewPaneRightRequest,
    ) -> cmux::raw::Result<cmux::raw::NewPaneRightResult> = cmux::raw::Client::new_pane_right;
    let _: fn(
        &mut cmux::raw::Client,
        cmux::raw::SetViewportPaneWidthRequest,
    ) -> cmux::raw::Result<cmux::raw::SetViewportPaneWidthResult> =
        cmux::raw::Client::set_viewport_pane_width;
    let _: fn(
        &mut cmux::raw::Client,
        cmux::raw::UndoLayoutRequest,
    ) -> cmux::raw::Result<cmux::raw::UndoLayoutResult> = cmux::raw::Client::undo_layout;

    assert_eq!(
        [
            cmux::raw::CLEAR_HISTORY_METADATA.name,
            cmux::raw::NEW_PANE_RIGHT_METADATA.name,
            cmux::raw::SET_VIEWPORT_PANE_WIDTH_METADATA.name,
            cmux::raw::UNDO_LAYOUT_METADATA.name,
        ],
        ["clear-history", "new-pane-right", "set-viewport-pane-width", "undo-layout"]
    );
}
