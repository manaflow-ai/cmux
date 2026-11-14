use super::HostLauncher;
use std::path::PathBuf;

/// A daemon whose binary an update replaced still starts agent hosts: on
/// Linux its own binary is exec'd from the open inode, never `PATH
/// (deleted)`, and argv0 stays the path (a copy named `acpmux` runs as
/// acpmux by it). Another binary is exec'd as given.
#[test]
fn the_host_starts_from_the_open_inode_on_linux() {
    let launcher = HostLauncher::current().expect("launcher");
    let exe = std::env::current_exe().expect("current exe");
    assert_eq!(launcher.exe, exe);
    if cfg!(target_os = "linux") {
        assert_eq!(launcher.program(), PathBuf::from("/proc/self/exe"));
    } else {
        assert_eq!(launcher.program(), exe);
    }
    let other = HostLauncher { exe: PathBuf::from("/opt/cmux/bin/acpmux"), prefix: Vec::new() };
    assert_eq!(other.program(), PathBuf::from("/opt/cmux/bin/acpmux"));
}
