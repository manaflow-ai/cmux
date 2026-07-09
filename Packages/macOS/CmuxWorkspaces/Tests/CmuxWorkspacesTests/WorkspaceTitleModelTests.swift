import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class WorkspaceTitleHostStub: WorkspaceTitleHosting {
    var title: String = ""
    var customTitle: String?
    var customTitleSource: CustomTitleSource?
    var customDescription: String?
    var processTitle: String = ""
    private(set) var applyProcessLogs: [(from: String, to: String)] = []
    private(set) var descriptionLogs: [(input: String?, normalized: String?)] = []

    var workspaceTitleText: String {
        get { title }
        set { title = newValue }
    }

    var workspaceTitleCustomTitle: String? {
        get { customTitle }
        set { customTitle = newValue }
    }

    var workspaceTitleCustomTitleSource: CustomTitleSource? {
        get { customTitleSource }
        set { customTitleSource = newValue }
    }

    var workspaceTitleCustomDescription: String? {
        get { customDescription }
        set { customDescription = newValue }
    }

    var workspaceTitleProcessTitle: String {
        get { processTitle }
        set { processTitle = newValue }
    }

    func workspaceTitleLogApplyProcess(from previousTitle: String, to title: String) {
        applyProcessLogs.append((previousTitle, title))
    }

    func workspaceTitleLogCustomDescriptionUpdate(input: String?, normalized: String?) {
        descriptionLogs.append((input, normalized))
    }
}

@MainActor
private func makeModel() -> (WorkspaceTitleModel, WorkspaceTitleHostStub) {
    let host = WorkspaceTitleHostStub()
    let model = WorkspaceTitleModel()
    model.attach(host: host)
    return (model, host)
}

@MainActor
@Suite struct WorkspaceTitleModelTests {
    @Test func userTitleSetsTitleAndProvenance() {
        let (model, host) = makeModel()
        #expect(model.setCustomTitle("My Title", source: .user))
        #expect(host.customTitle == "My Title")
        #expect(host.customTitleSource == .user)
        #expect(host.title == "My Title")
        #expect(model.hasCustomTitle)
        #expect(model.effectiveCustomTitleSource == .user)
    }

    @Test func titleIsTrimmed() {
        let (model, host) = makeModel()
        #expect(model.setCustomTitle("  spaced  ", source: .user))
        #expect(host.customTitle == "spaced")
        #expect(host.title == "spaced")
    }

    @Test func autoTitleRejectedWhenUserTitleExists() {
        let (model, host) = makeModel()
        #expect(model.setCustomTitle("User", source: .user))
        #expect(!model.setCustomTitle("Auto", source: .auto))
        #expect(host.customTitle == "User")
        #expect(host.customTitleSource == .user)
    }

    @Test func autoTitleAcceptedWhenNoUserTitle() {
        let (model, host) = makeModel()
        #expect(model.setCustomTitle("Auto", source: .auto))
        #expect(host.customTitle == "Auto")
        #expect(host.customTitleSource == .auto)
        #expect(model.effectiveCustomTitleSource == .auto)
    }

    @Test func autoTitleNeverClears() {
        let (model, host) = makeModel()
        #expect(model.setCustomTitle("Auto", source: .auto))
        #expect(!model.setCustomTitle("", source: .auto))
        #expect(host.customTitle == "Auto")
    }

    @Test func emptyUserTitleClearsToProcessTitle() {
        let (model, host) = makeModel()
        host.processTitle = "proc"
        _ = model.setCustomTitle("Custom", source: .user)
        #expect(model.setCustomTitle(nil, source: .user))
        #expect(host.customTitle == nil)
        #expect(host.customTitleSource == nil)
        #expect(host.title == "proc")
        #expect(!model.hasCustomTitle)
        #expect(model.effectiveCustomTitleSource == nil)
    }

    @Test func autoTitleReplacesPriorAutoTitle() {
        let (model, host) = makeModel()
        _ = model.setCustomTitle("Auto1", source: .auto)
        #expect(model.setCustomTitle("Auto2", source: .auto))
        #expect(host.customTitle == "Auto2")
        #expect(host.customTitleSource == .auto)
    }

    @Test func effectiveSourceDefaultsToUserWhenProvenanceMissing() {
        let (model, host) = makeModel()
        host.customTitle = "Carried"
        host.customTitleSource = nil
        #expect(model.effectiveCustomTitleSource == .user)
    }

    @Test func applyProcessTitlePromotesWhenNoCustomTitle() {
        let (model, host) = makeModel()
        model.applyProcessTitle("zsh")
        #expect(host.processTitle == "zsh")
        #expect(host.title == "zsh")
        #expect(host.applyProcessLogs.count == 1)
    }

    @Test func applyProcessTitleDoesNotPromoteWithCustomTitle() {
        let (model, host) = makeModel()
        _ = model.setCustomTitle("Pinned", source: .user)
        model.applyProcessTitle("zsh")
        #expect(host.processTitle == "zsh")
        #expect(host.title == "Pinned")
    }

    @Test func applyProcessTitleNoOpWhenUnchanged() {
        let (model, host) = makeModel()
        host.title = "same"
        host.processTitle = "same"
        model.applyProcessTitle("same")
        #expect(host.applyProcessLogs.isEmpty)
    }

    @Test func descriptionNormalizesLineEndingsButPreservesInnerWhitespace() {
        // Legacy returns the normalized (un-trimmed) string when non-empty;
        // trimming is only used to decide nil-vs-present, so trailing spaces
        // survive. This pins that quirk.
        let (model, host) = makeModel()
        model.setCustomDescription("a\r\nb\rc  ")
        #expect(host.customDescription == "a\nb\nc  ")
        #expect(model.hasCustomDescription)
    }

    @Test func emptyDescriptionBecomesNil() {
        let (model, host) = makeModel()
        model.setCustomDescription("   \n  ")
        #expect(host.customDescription == nil)
        #expect(!model.hasCustomDescription)
    }

    @Test func normalizedCustomDescriptionStatic() {
        #expect(WorkspaceTitleModel.normalizedCustomDescription(nil) == nil)
        #expect(WorkspaceTitleModel.normalizedCustomDescription("") == nil)
        #expect(WorkspaceTitleModel.normalizedCustomDescription("x\r\ny") == "x\ny")
    }
}
