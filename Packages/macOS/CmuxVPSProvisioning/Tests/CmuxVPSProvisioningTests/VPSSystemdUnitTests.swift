import Testing
@testable import CmuxVPSProvisioning

@Suite("VPSSystemdUnit and remote scripts")
struct VPSSystemdUnitTests {
    private let layout = VPSRemoteLayout(
        homeDirectory: "/home/dev/",
        version: "0.99.0",
        goOS: "linux",
        goArch: "amd64"
    )

    @Test("layout pins the bootstrap-shared binary path and unit paths")
    func layoutPaths() {
        #expect(layout.binaryPath == "/home/dev/.cmux/bin/cmuxd-remote/0.99.0/linux-amd64/cmuxd-remote")
        #expect(layout.currentSymlinkPath == "/home/dev/.cmux/vps/current")
        #expect(layout.unitFilePath(scope: .user) == "/home/dev/.config/systemd/user/cmux-vps.service")
        #expect(layout.unitFilePath(scope: .system) == "/etc/systemd/system/cmux-vps.service")
    }

    @Test("user unit executes the current symlink with idle exit disabled")
    func userUnitContent() {
        let unit = VPSSystemdUnit(layout: layout, scope: .user)
        let content = unit.fileContent()
        #expect(content.contains(
            "ExecStart=/home/dev/.cmux/vps/current serve --persistent-server --slot vps --idle-timeout 0"
        ))
        #expect(content.contains("WantedBy=default.target"))
        #expect(content.contains("Restart=on-failure"))
        #expect(content.hasSuffix("\n"))
    }

    @Test("system unit wants multi-user.target")
    func systemUnitContent() {
        let unit = VPSSystemdUnit(layout: layout, scope: .system)
        #expect(unit.fileContent().contains("WantedBy=multi-user.target"))
    }

    @Test("unit hash is stable and scope-sensitive")
    func unitHash() {
        let user = VPSSystemdUnit(layout: layout, scope: .user)
        #expect(user.contentSHA256() == VPSSystemdUnit(layout: layout, scope: .user).contentSHA256())
        #expect(user.contentSHA256() != VPSSystemdUnit(layout: layout, scope: .system).contentSHA256())
        #expect(user.contentSHA256().count == 64)
    }

    @Test("finalize script verifies the checksum before installing")
    func finalizeScript() {
        let scripts = VPSRemoteScripts(layout: layout)
        let script = scripts.finalizeBinaryScript(tempPath: "/tmp/upload.tmp", expectedSHA256: "ABCDEF")
        #expect(script.contains("sha256sum"))
        #expect(script.contains("shasum -a 256"))
        #expect(script.contains("'abcdef'"))
        #expect(script.contains("exit 65"))
        #expect(script.contains("chmod 755"))
        #expect(script.contains("mv '/tmp/upload.tmp' '/home/dev/.cmux/bin/cmuxd-remote/0.99.0/linux-amd64/cmuxd-remote'"))
    }

    @Test("user-scope systemctl pins XDG_RUNTIME_DIR")
    func systemctlPrefix() {
        let scripts = VPSRemoteScripts(layout: layout)
        #expect(scripts.systemctlPrefix(scope: .user) == "env XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user")
        #expect(scripts.systemctlPrefix(scope: .system) == "systemctl")
        #expect(scripts.restartUnitScript(scope: .system) == "systemctl restart 'cmux-vps.service'")
    }

    @Test("unit write script embeds the unit content in a quoted heredoc")
    func unitWriteScript() {
        let scripts = VPSRemoteScripts(layout: layout)
        let unit = VPSSystemdUnit(layout: layout, scope: .user)
        let script = scripts.writeUnitFileScript(
            path: layout.unitFilePath(scope: .user),
            content: unit.fileContent()
        )
        #expect(script.contains("<<'CMUX_UNIT_EOF'"))
        #expect(script.contains("[Service]"))
        #expect(script.hasSuffix("CMUX_UNIT_EOF"))
    }

    @Test("hello script rides the persistent slot the unit serves")
    func helloScript() {
        let scripts = VPSRemoteScripts(layout: layout)
        let script = scripts.stdioHelloScript(binaryPath: layout.binaryPath)
        #expect(script.contains("serve --stdio --persistent --slot 'vps'"))
        #expect(script.contains(#"{"id":1,"method":"hello","params":{}}"#))
    }
}
