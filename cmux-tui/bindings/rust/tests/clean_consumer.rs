//! This integration crate intentionally uses only installed public paths.

use cmux::{
    Browser, BrowserAttachment, BrowserViewerResizeResult, Client, Config, CreateScreenOptions,
    CreationResolution, Error, Machine, Pane, PixelSize, Screen, Selector, Session, Size, Tab,
    Terminal, TerminalAttachment, TerminalWaitExitResult, UndoLayoutOptions, ViewerReleaseResult,
    ViewerResizeResult, Workspace, WorkspaceId,
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

    fn typed_recovery_reads(session: &Session, terminal: &Terminal) {
        let _: cmux::Result<CreationResolution> =
            session.creation().resolve("consumer-correlation");
        let _: cmux::Result<TerminalWaitExitResult> = terminal.wait_exit(Some(0));
    }
    let _ = typed_recovery_reads as fn(&Session, &Terminal);
    let _: fn(&mut TerminalAttachment, Size) -> cmux::Result<ViewerResizeResult> =
        TerminalAttachment::resize;
    let _: fn(&mut TerminalAttachment) -> cmux::Result<ViewerReleaseResult> =
        TerminalAttachment::release;
    let _: fn(&mut BrowserAttachment, PixelSize) -> cmux::Result<BrowserViewerResizeResult> =
        BrowserAttachment::resize;
    let _: fn(&mut BrowserAttachment) -> cmux::Result<ViewerReleaseResult> =
        BrowserAttachment::release;
    let _undo = UndoLayoutOptions {
        confirm_close: true,
        confirmation_token: Some("preview-token".to_string()),
    };
    let _creation = CreateScreenOptions::default().correlation_key("consumer-correlation").unwrap();
    fn typed_confirmation(error: Error) -> Option<cmux::ConfirmationRequiredDetails> {
        match error {
            Error::ConfirmationRequired { details, .. } => Some(details),
            _ => None,
        }
    }
    let _ = typed_confirmation as fn(Error) -> Option<cmux::ConfirmationRequiredDetails>;
}

#[test]
fn newly_cataloged_raw_commands_are_public() {
    let _: fn(
        &mut cmux::raw::Client,
        cmux::raw::BrowserFramePresentedRequest,
    ) -> cmux::raw::Result<cmux::raw::BrowserFramePresentedResult> =
        cmux::raw::Client::browser_frame_presented;
    let _: fn(
        &mut cmux::raw::Client,
        cmux::raw::BrowserKeyPressRequest,
    ) -> cmux::raw::Result<cmux::raw::BrowserKeyPressResult> = cmux::raw::Client::browser_key_press;
    let _: fn(
        &mut cmux::raw::Client,
        cmux::raw::BrowserMouseGuardedRequest,
    ) -> cmux::raw::Result<cmux::raw::BrowserMouseGuardedResult> =
        cmux::raw::Client::browser_mouse_guarded;
    let _: fn(
        &mut cmux::raw::Client,
        cmux::raw::BrowserWheelGuardedRequest,
    ) -> cmux::raw::Result<cmux::raw::BrowserWheelGuardedResult> =
        cmux::raw::Client::browser_wheel_guarded;
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
            cmux::raw::BROWSER_FRAME_PRESENTED_METADATA.name,
            cmux::raw::BROWSER_KEY_PRESS_METADATA.name,
            cmux::raw::BROWSER_MOUSE_GUARDED_METADATA.name,
            cmux::raw::BROWSER_WHEEL_GUARDED_METADATA.name,
            cmux::raw::CLEAR_HISTORY_METADATA.name,
            cmux::raw::NEW_PANE_RIGHT_METADATA.name,
            cmux::raw::SET_VIEWPORT_PANE_WIDTH_METADATA.name,
            cmux::raw::UNDO_LAYOUT_METADATA.name,
        ],
        [
            "browser-frame-presented",
            "browser-key-press",
            "browser-mouse-guarded",
            "browser-wheel-guarded",
            "clear-history",
            "new-pane-right",
            "set-viewport-pane-width",
            "undo-layout",
        ]
    );
}
