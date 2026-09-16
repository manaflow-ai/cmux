pub mod browser;
pub mod cloud;
pub mod cloud_attach;
pub mod cloud_execution;
pub mod coderouter;
pub mod config;
pub mod hook_state;
pub mod hooks;
pub mod integrations;
pub mod notifications;
pub mod open_diff;
pub mod sessions;
pub mod simulator;
pub mod terminal;
pub mod tmux;
pub mod topology;
pub const ALL: &[fn(&crate::Context, &str, &[String]) -> crate::Result<Option<i32>>] = &[
    topology::run,
    tmux::run,
    terminal::run,
    browser::run,
    cloud::run,
    cloud_execution::run,
    cloud_attach::run,
    hooks::run,
    hook_state::run,
    integrations::run,
    sessions::run,
    open_diff::run,
    config::run,
    notifications::run,
    simulator::run,
    coderouter::run,
];
