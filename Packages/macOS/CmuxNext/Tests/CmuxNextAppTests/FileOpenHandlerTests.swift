import CmuxNextActions
import Foundation
import Testing
@testable import CmuxNextApp

/// `file.open` through the real AgentHandlers (#16773): what the palette,
/// `cmux file open` and the agent pane hear back when a file does not open.
/// No window is open here, so nothing opens; every case is a refusal.
@MainActor @Suite struct FileOpenHandlerTests {
    /// The app's own registry: a handler's context refuses into
    /// `services.registry`, so a refusal is captured only there.
    private func make() -> ActionRegistry {
        let services = AppServices(environment: AppEnvironment.current([:]))
        AgentHandlers.bind(into: services.registry, context: AppActionContext(services: services))
        return services.registry
    }

    private func refusal(_ registry: ActionRegistry, _ arguments: [String: ActionValue], target: ActionTargetRef? = nil) -> String? {
        registry.capturingRefusal {
            _ = registry.perform("file.open", invocation: ActionInvocation(target: target, arguments: arguments))
        }
    }

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-open-handler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func aFolderIsNotAFile() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let reason = refusal(make(), ["path": .string(root.path)])
        #expect(reason == MiscHandlerStrings.fileNotFound(root.path))
    }

    /// The CLI sends the path as typed, so a relative one says what is wrong
    /// with it rather than that the file is missing.
    @Test func aRelativePathAsksForAnAbsoluteOne() throws {
        let reason = try #require(refusal(make(), ["path": .string("README.md")]))
        #expect(reason == MiscHandlerStrings.pathNotAbsolute("README.md"))
    }

    @Test func aPageOpensInTheEditorOnly() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("index.html")
        try Data("<p>".utf8).write(to: page)
        let reason = refusal(make(), ["path": .string(page.path), "where": .string("tab")])
        #expect(reason == MiscHandlerStrings.fileNotInTab(page.path))
    }

    /// An explicit pane is where the tab goes; one no window shows is refused
    /// by name, not swapped for the focused pane.
    @Test func anExplicitPaneTargetIsTheOneUsed() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Retry.swift")
        try Data("x".utf8).write(to: file)
        let pane = ActionTargetRef(kind: .pane, id: "pane-gone")
        let reason = try #require(refusal(make(), ["path": .string(file.path)], target: pane))
        #expect(reason.contains("pane:pane-gone"), "\(reason)")
    }

    /// The registry checks a palette or CLI choice, but an in-app caller can
    /// still pass anything; that is refused, never a silent no-op.
    @Test func anUnknownPlaceIsRefusedNamingTheChoices() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Retry.swift")
        try Data("x".utf8).write(to: file)
        let reason = try #require(refusal(make(), ["path": .string(file.path), "where": .string("finder")]))
        #expect(reason == MiscHandlerStrings.invalidPlace("finder"))
    }
}
