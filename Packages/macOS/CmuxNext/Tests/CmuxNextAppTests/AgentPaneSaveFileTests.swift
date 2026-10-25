@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The side panel's Save (cx-ncc.75, Claude parity): `pane.saveFile` hands a document to the pane's
/// save panel under a plain file name with its kind's extension, as the inspector's `pane.saveLog`
/// hands its log. Another kind, no text, or no save panel is refused; a cancelled panel answers false.
@MainActor
struct AgentPaneSaveFileTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func ask(_ model: AgentPaneModel, _ method: String, _ params: [String: Any]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    @Test func savesADocumentUnderItsKindsExtension() async {
        let model = AgentPaneModel(host: NoHost())
        var saved: [AgentPaneSave] = []
        var answer = true
        model.onSaveFile = { save in
            saved.append(save)
            return answer
        }
        let html = await Self.ask(model, "pane.saveFile", ["text": "<h1>Hi</h1>", "suggestedName": "Quarterly report", "kind": "html"])
        #expect(Self.errorCode(html) == nil, "\(html)")
        #expect(html["value"] as? Bool == true)
        #expect(saved.map(\.suggestedName) == ["Quarterly report.html"])
        #expect(saved.map(\.text) == ["<h1>Hi</h1>"])
        #expect(saved.map(\.kind) == [.html])

        // A name with a path and the extension already on it stays one plain file name.
        _ = await Self.ask(model, "pane.saveFile", ["text": "<svg/>", "suggestedName": "../../chart.SVG", "kind": "svg"])
        _ = await Self.ask(model, "pane.saveFile", ["text": "# Plan", "kind": "markdown"])
        _ = await Self.ask(model, "pane.saveFile", ["text": "<p/>", "suggestedName": ". .profile", "kind": "html"])
        #expect(saved.map(\.suggestedName).suffix(3) == ["chart.svg", "document.md", "profile.html"])

        answer = false
        let cancelled = await Self.ask(model, "pane.saveFile", ["text": "# Plan", "suggestedName": "Plan", "kind": "markdown"])
        #expect(cancelled["value"] as? Bool == false)

        // The inspector's log takes the same path, as JSON Lines.
        answer = true
        _ = await Self.ask(model, "pane.saveLog", ["text": "{}\n", "suggestedName": ""])
        #expect(saved.last?.suggestedName == "acp.jsonl")
        #expect(saved.last?.kind == .log)
    }

    @Test func refusesAnotherKindNoTextOrNoSavePanel() async {
        let model = AgentPaneModel(host: NoHost())
        var saved = 0
        model.onSaveFile = { _ in
            saved += 1
            return true
        }
        #expect(Self.errorCode(await Self.ask(model, "pane.saveFile", ["text": "x", "kind": "log"])) == "unsupported")
        #expect(Self.errorCode(await Self.ask(model, "pane.saveFile", ["text": "x", "kind": "app"])) == "unsupported")
        #expect(Self.errorCode(await Self.ask(model, "pane.saveFile", ["text": "", "kind": "html"])) == "unsupported")
        #expect(saved == 0)

        model.onSaveFile = nil
        #expect(Self.errorCode(await Self.ask(model, "pane.saveFile", ["text": "x", "kind": "html"])) == "unsupported")
    }

    @Test func opensAnArtifactThroughTheNativeCallback() async {
        let model = AgentPaneModel(host: NoHost())
        var opened: [AgentPaneSave] = []
        model.onOpenArtifact = { save in
            opened.append(save)
            return true
        }
        let reply = await Self.ask(model, "pane.openArtifact", [
            "text": "<h1>Hi</h1>", "suggestedName": "../../Quarterly.HTML", "kind": "html",
        ])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect(reply["value"] as? Bool == true)
        #expect(opened.map(\.suggestedName) == ["Quarterly.html"])

        model.onOpenArtifact = nil
        #expect(Self.errorCode(await Self.ask(model, "pane.openArtifact", ["text": "x", "kind": "html"])) == "unsupported")
        #expect(Self.errorCode(await Self.ask(model, "pane.openArtifact", ["text": "x", "kind": "log"])) == "unsupported")
    }

    @Test func artifactWriterKeepsNamesAndBytesInPrivateTempDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-writer-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let save = AgentPaneSave(text: "<svg>safe</svg>", suggestedName: "../../chart.SVG", kind: .svg)!
        let file = try #require(AgentPaneArtifactFileWriter(directory: base).write(save))
        #expect(file.path.hasPrefix(base.resolvingSymlinksInPath().path + "/"))
        #expect(file.lastPathComponent == "chart.svg")
        #expect(try String(contentsOf: file, encoding: .utf8) == save.text)
        let folder = file.deletingLastPathComponent()
        let folderMode = try #require(FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)
        let fileMode = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        #expect(folderMode.uint16Value & 0o777 == 0o700)
        #expect(fileMode.uint16Value & 0o777 == 0o600)
    }
}
