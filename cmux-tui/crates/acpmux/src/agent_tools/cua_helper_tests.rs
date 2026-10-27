use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use super::super::{AgentTools, Inputs, resolve_with_cua_helper};

struct Fixture {
    root: PathBuf,
    exe: PathBuf,
}

impl Fixture {
    fn new(bundle_id: &str) -> Self {
        let root = std::env::temp_dir().join(format!("acpmux-cua-dev-{}", uuid::Uuid::now_v7()));
        let exe = root.join("cmux.app/Contents/Resources/bin/acpmux");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        let fixture = Self { root, exe };
        let info = plist::Value::Dictionary(
            [("CFBundleIdentifier".to_owned(), plist::Value::String(bundle_id.to_owned()))]
                .into_iter()
                .collect(),
        );
        info.to_file_xml(fixture.info()).unwrap();
        fixture
    }

    fn info(&self) -> PathBuf {
        self.exe.parent().unwrap().parent().unwrap().parent().unwrap().join("Info.plist")
    }

    fn roots(&self) -> Vec<PathBuf> {
        vec![self.root.join("Applications"), self.root.join("home/Applications")]
    }

    fn helper(&self, root: usize, app: Option<&str>) -> PathBuf {
        let root = self.roots().remove(root);
        let helper = match app {
            Some(name) => root.join(name).join("Contents/Library").join(super::HELPER_APP),
            None => root.join(super::HELPER_APP),
        };
        Self::write_executable(&helper.join(super::HELPER_BINARY));
        helper
    }

    fn write_executable(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn inputs(&self) -> Inputs {
        Inputs {
            enabled: true,
            bin_dir: self.exe.parent().map(Path::to_path_buf),
            cmux_json: None,
            state_dir: self.root.join("state"),
            cua: crate::cua_socket::select(
                Some("/tag/cua.sock".into()),
                Some("agent-token".into()),
            ),
            cua_v2: None,
            acpmux: Some(crate::self_command::SelfCommand::new(self.exe.clone(), vec![])),
            secrets: false,
            offers: false,
            subsessions: false,
            displays: None,
        }
    }

    fn resolve(&self, checker: impl FnMut(&Path) -> bool) -> AgentTools {
        resolve_with_cua_helper(&self.inputs(), |exe| super::find(exe, || self.roots(), checker))
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn cua(tools: AgentTools) -> Option<super::super::McpServer> {
    tools.servers.into_iter().find(|server| server.name == "cmux-cua")
}

#[test]
fn release_without_a_bundled_helper_gets_no_cua_server() {
    for id in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc"] {
        let fixture = Fixture::new(id);
        fixture.helper(0, Some("cmux NIGHTLY.app"));
        assert!(
            cua(fixture.resolve(|_| panic!("release must not check installed helpers"))).is_none()
        );
        assert!(
            super::find(&fixture.exe, || panic!("release must not look up candidates"), |_| true)
                .is_none()
        );
    }
}

#[test]
fn dev_without_a_bundled_helper_gets_a_signed_installed_cua_server() {
    let fixture = Fixture::new("com.cmuxterm.app.debug.cua");
    let helper = fixture.helper(0, Some("cmux NIGHTLY.app"));
    let mut checked = vec![];
    let server = cua(fixture.resolve(|path| {
        checked.push(path.to_owned());
        true
    }))
    .expect("DEV needs the installed client even when it was not known at daemon spawn");
    assert_eq!(checked, std::slice::from_ref(&helper));
    assert_eq!(server.command, helper.join(super::HELPER_BINARY));
    assert_eq!(server.args, ["mcp", "--socket", "/tag/cua.sock"]);
    assert!(server.env.contains(&("CMUX_CUA_SOCKET_AUTH_TOKEN".into(), "agent-token".into())));
    assert!(server.env.contains(&("CMUX_CUA_MCP_FORCE_PROXY".into(), "1".into())));
}

#[test]
fn cua_signature_failure_skips_the_candidate_and_fails_closed() {
    let fixture = Fixture::new("com.cmuxterm.app.debug");
    let nightly = fixture.helper(0, Some("cmux NIGHTLY.app"));
    let rc = fixture.helper(0, Some("cmux RC.app"));
    let mut checked = vec![];
    assert_eq!(
        cua(fixture.resolve(|helper| {
            checked.push(helper.to_owned());
            helper != nightly
        }))
        .unwrap()
        .command,
        rc.join(super::HELPER_BINARY)
    );
    assert_eq!(checked, [nightly, rc]);
    assert!(cua(fixture.resolve(|_| false)).is_none());
}

#[test]
fn cua_candidates_follow_swift_order_in_both_application_roots() {
    let fixture = Fixture::new("com.cmuxterm.app.debug.cua");
    let mut expected = vec![];
    for root in [0, 1] {
        for app in [Some("cmux NIGHTLY.app"), Some("cmux RC.app"), Some("cmux.app"), None] {
            expected.push(fixture.helper(root, app));
        }
    }
    // Remove the chosen copy each time. The next candidate must then win.
    for helper in expected {
        let binary = helper.join(super::HELPER_BINARY);
        assert_eq!(cua(fixture.resolve(|_| true)).unwrap().command, binary);
        std::fs::remove_file(binary).unwrap();
    }
    assert!(cua(fixture.resolve(|_| panic!("no binary to check"))).is_none());
}

#[test]
fn cua_bundled_clients_win_without_an_installed_signature_check() {
    let fixture = Fixture::new("com.cmuxterm.app.debug.cua");
    fixture.helper(0, Some("cmux NIGHTLY.app"));
    let nested = fixture
        .info()
        .parent()
        .unwrap()
        .join("Library")
        .join(super::HELPER_APP)
        .join(super::HELPER_BINARY);
    Fixture::write_executable(&nested);
    let own = fixture.exe.parent().unwrap().join("cmux-cua");
    Fixture::write_executable(&own);
    assert_eq!(cua(fixture.resolve(|_| panic!("own binary wins"))).unwrap().command, own);
    std::fs::remove_file(own).unwrap();
    assert_eq!(cua(fixture.resolve(|_| panic!("nested binary wins"))).unwrap().command, nested);
}

#[test]
fn cua_dev_identity_comes_from_the_executable_bundle_plist() {
    let fixture = Fixture::new("com.cmuxterm.app.debug.cua");
    fixture.helper(0, Some("cmux NIGHTLY.app"));
    let info = plist::Value::from_file(fixture.info()).unwrap();
    info.to_file_binary(fixture.info()).unwrap();
    assert!(cua(fixture.resolve(|_| true)).is_some(), "binary plists must work too");

    // A DEV bin override does not turn a release executable into a DEV app.
    let release = Fixture::new("com.cmuxterm.app");
    let mut inputs = release.inputs();
    inputs.bin_dir = fixture.inputs().bin_dir;
    let tools = resolve_with_cua_helper(&inputs, |exe| {
        super::find(exe, || fixture.roots(), |_| panic!("exe identity must win"))
    });
    assert!(cua(tools).is_none());

    for invalid in [b"not a plist".as_slice(), b"<plist><dict/></plist>".as_slice()] {
        std::fs::write(fixture.info(), invalid).unwrap();
        assert!(cua(fixture.resolve(|_| panic!("no DEV identity"))).is_none());
    }
    std::fs::remove_file(fixture.info()).unwrap();
    assert!(cua(fixture.resolve(|_| panic!("missing plist"))).is_none());
}
