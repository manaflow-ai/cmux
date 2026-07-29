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
