import Foundation
import Testing
@testable import CmuxNextUpdater

/// `StoreSchemaProbe` runs a bundle's own CLI (`cmux __store-schemas`) and
/// takes only a clean JSON object of integers from it.
@Suite struct StoreSchemaProbeTests {
    /// A bundle whose `bin/cmux` answers like cmux-tui: what it reads, or
    /// (`--stored`) the schemas in `$CMUX_TUI_STATE_DIR/stored.json`.
    private func fakeBundle(_ script: String) throws -> URL {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "probe-\(UUID().uuidString).app")
        let bin = bundle.appending(path: "Contents/Resources/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appending(path: "cmux")
        try ("#!/bin/sh\n" + script).write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return bundle
    }

    private let answering = """
        [ "$1" = __store-schemas ] || exit 2
        if [ "$2" = --stored ]; then cat "$CMUX_TUI_STATE_DIR/stored.json"; else echo '{"conversation_store":2,"workspace_registry":15}'; fi
        """

    @Test func readsWhatTheBuildReads() throws {
        let bundle = try fakeBundle(answering)
        #expect(StoreSchemaProbe(bundle: bundle).readable() == ["conversation_store": 2, "workspace_registry": 15])
    }

    @Test func storedTakesTheNewestAcrossStateDirectories() throws {
        let bundle = try fakeBundle(answering)
        let roots = try ["{\"workspace_registry\":14}", "{\"workspace_registry\":15,\"conversation_store\":2}"].map { json in
            let root = FileManager.default.temporaryDirectory.appending(path: "state-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try json.write(to: root.appending(path: "stored.json"), atomically: true, encoding: .utf8)
            return root
        }
        #expect(StoreSchemaProbe(bundle: bundle).stored(stateDirectories: roots) == ["workspace_registry": 15, "conversation_store": 2])
    }

    /// An older build without the probe, a failing read, or odd output say
    /// nothing, so the rollback refuses instead of guessing.
    @Test func failuresAndOddOutputSayNothing() throws {
        #expect(StoreSchemaProbe(bundle: try fakeBundle("exit 2")).readable() == nil)
        #expect(StoreSchemaProbe(bundle: try fakeBundle("echo '{\"a\":true}'")).readable() == nil)
        #expect(StoreSchemaProbe(bundle: try fakeBundle("echo '[1]'")).readable() == nil)
        let missing = FileManager.default.temporaryDirectory.appending(path: "absent-\(UUID().uuidString).app")
        #expect(StoreSchemaProbe(bundle: missing).readable() == nil)
        #expect(StoreSchemaProbe(bundle: try fakeBundle("exit 1")).stored(stateDirectories: [nil]) == nil)
    }
}
