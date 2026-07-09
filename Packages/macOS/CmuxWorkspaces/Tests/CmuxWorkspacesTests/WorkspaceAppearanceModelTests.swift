import Testing
@testable import CmuxWorkspaces

@MainActor
private final class WorkspaceAppearanceHostStub: WorkspaceAppearanceHosting {
    var customColor: String?
    var terminalScrollBarHidden: Bool = false
    private(set) var scrollBarDidChangePostCount = 0
    /// When `true`, ``workspaceAppearanceNormalizedColorHex(_:)`` returns `nil`
    /// for any input, mirroring a malformed hex (legacy
    /// `WorkspaceTabColorSettings.normalizedHex` rejecting bad input).
    var rejectAllHex = false

    var workspaceAppearanceCustomColor: String? {
        get { customColor }
        set { customColor = newValue }
    }

    var workspaceAppearanceTerminalScrollBarHidden: Bool {
        get { terminalScrollBarHidden }
        set { terminalScrollBarHidden = newValue }
    }

    func workspaceAppearanceNormalizedColorHex(_ hex: String) -> String? {
        guard !rejectAllHex else { return nil }
        // Mirrors the canonical `#RRGGBB` uppercasing the app-target
        // `WorkspaceTabColorSettings.normalizedHex` performs for valid input.
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6 else { return nil }
        return "#" + trimmed.uppercased()
    }

    func workspaceAppearancePostTerminalScrollBarHiddenDidChange() {
        scrollBarDidChangePostCount += 1
    }
}

@MainActor
private func makeModel() -> (WorkspaceAppearanceModel, WorkspaceAppearanceHostStub) {
    let host = WorkspaceAppearanceHostStub()
    let model = WorkspaceAppearanceModel()
    model.attach(host: host)
    return (model, host)
}

@MainActor
@Suite struct WorkspaceAppearanceModelTests {
    @Test func setCustomColorNormalizesNonNilHex() {
        let (model, host) = makeModel()
        model.setCustomColor("#c0392b")
        #expect(host.customColor == "#C0392B")
    }

    @Test func setCustomColorClearsForNil() {
        let (model, host) = makeModel()
        host.customColor = "#C0392B"
        model.setCustomColor(nil)
        #expect(host.customColor == nil)
    }

    @Test func setCustomColorMalformedHexClearsColor() {
        // Legacy assigns `normalizedHex(...)` directly, so a malformed hex
        // (which normalizes to nil) clears the color rather than rejecting it.
        let (model, host) = makeModel()
        host.customColor = "#C0392B"
        host.rejectAllHex = true
        model.setCustomColor("not-a-color")
        #expect(host.customColor == nil)
    }

    @Test func setTerminalScrollBarHiddenWritesAndPostsOnChange() {
        let (model, host) = makeModel()
        model.setTerminalScrollBarHidden(true)
        #expect(host.terminalScrollBarHidden)
        #expect(host.scrollBarDidChangePostCount == 1)
    }

    @Test func setTerminalScrollBarHiddenNoOpsWhenUnchanged() {
        let (model, host) = makeModel()
        host.terminalScrollBarHidden = true
        model.setTerminalScrollBarHidden(true)
        #expect(host.terminalScrollBarHidden)
        #expect(host.scrollBarDidChangePostCount == 0)
    }

    @Test func setTerminalScrollBarHiddenPostsOnEachDistinctChange() {
        let (model, host) = makeModel()
        model.setTerminalScrollBarHidden(true)
        model.setTerminalScrollBarHidden(false)
        #expect(!host.terminalScrollBarHidden)
        #expect(host.scrollBarDidChangePostCount == 2)
    }
}
