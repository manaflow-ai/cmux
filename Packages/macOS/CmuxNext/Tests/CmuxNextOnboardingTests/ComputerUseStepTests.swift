import AppKit
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// The computer use step: shown only when the App has the helper's grants,
/// each row Allow until macOS has the grant, the drag tile only while a
/// grant is pending, and the grants followed only while the step shows.
@MainActor
@Suite struct ComputerUseStepTests {
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    @Test func theStepIsLeftOutWithoutTheHelper() {
        #expect(!OnboardingModel(services: MockOnboardingServices(), start: .computerUse).steps.contains(.computerUse))
        let services = MockOnboardingServices()
        services.computerUseSource = MockComputerUsePermissionSource()
        #expect(OnboardingModel(services: services, start: .computerUse).steps == [.computerUse])
        #expect(!OnboardingModel(services: services).steps.contains(.computerUse), "the first run asks for no grants")
    }

    @Test func rowsFollowTheGrantsWhileTheStepShows() async {
        let source = MockComputerUsePermissionSource()
        let services = MockOnboardingServices()
        services.computerUseSource = source
        let model = OnboardingModel(services: services, start: .computerUse)
        model.stepDidAppear()
        source.current.accessibility = true
        await settle { model.computerUse.permissions.accessibility }
        #expect(model.computerUse.permissions == ComputerUsePermissions(accessibility: true, screenRecording: false))
        // Closing the window stops following: a later grant is not read.
        model.finish(completed: true)
        source.current.screenRecording = true
        for _ in 0..<50 { await Task.yield() }
        #expect(!model.computerUse.permissions.screenRecording)
    }

    /// A grant already queued when the step stops is dropped, not applied
    /// after the step is gone.
    @Test func aGrantQueuedBeforeStopIsNotApplied() async {
        let source = MockComputerUsePermissionSource()
        let model = ComputerUseStepModel(source: source)
        model.start()
        source.current.screenRecording = true
        let following = model.task
        model.stop()
        // The cancelled loop runs to its end, so whatever it would apply has been.
        await following?.value
        #expect(model.permissions == .none)
    }

    @Test func allowOpensTheListAndTheTileGoesWhenTheGrantLands() async {
        let source = MockComputerUsePermissionSource()
        let services = MockOnboardingServices()
        services.computerUseSource = source
        let model = OnboardingModel(services: services, start: .computerUse)
        model.stepDidAppear()
        model.computerUse.allow(.screenRecording)
        #expect(source.opened == [.screenRecording])
        #expect(model.computerUse.helping == .screenRecording)
        source.current.screenRecording = true
        await settle { model.computerUse.helping == nil }
        #expect(model.computerUse.helping == nil)
        // A granted row has nothing to allow.
        model.computerUse.allow(.screenRecording)
        #expect(source.opened == [.screenRecording] && model.computerUse.helping == nil)
    }

    /// A dev build with no Developer ID signed helper: Allow opens no list,
    /// floats no tile (nothing to grant that the TCC row would accept) and
    /// the step says computer use is unavailable in this build.
    @Test func withoutASignedHelperAllowReportsUnavailable() async {
        let source = MockComputerUsePermissionSource(helperAppURL: nil)
        let services = MockOnboardingServices()
        services.computerUseSource = source
        let model = OnboardingModel(services: services, start: .computerUse)
        model.stepDidAppear()
        let view = ComputerUseStepView(model: model.computerUse)
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 260)
        #expect(!Self.shownText(view).contains(OnboardingStrings.computerUseHelperUnavailable))
        model.computerUse.allow(.screenRecording)
        #expect(source.opened.isEmpty)
        #expect(model.computerUse.helping == nil)
        #expect(model.computerUse.unavailable)
        await settle { Self.shownText(view).contains(OnboardingStrings.computerUseHelperUnavailable) }
        #expect(Self.shownText(view).contains(OnboardingStrings.computerUseHelperUnavailable))
        model.finish(completed: true)
    }

    /// A helper that does not speak this build's protocol: the step says
    /// the versions do not match instead of showing nothing.
    @Test func aHelperVersionMismatchIsShown() async {
        let source = MockComputerUsePermissionSource(current: .helperVersionMismatch)
        let services = MockOnboardingServices()
        services.computerUseSource = source
        let model = OnboardingModel(services: services, start: .computerUse)
        let view = ComputerUseStepView(model: model.computerUse)
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 260)
        model.stepDidAppear()
        await settle { Self.shownText(view).contains(OnboardingStrings.computerUseHelperVersionMismatch) }
        #expect(Self.shownText(view).contains(OnboardingStrings.computerUseHelperVersionMismatch))
        source.current = .none
        await settle { !Self.shownText(view).contains(OnboardingStrings.computerUseHelperVersionMismatch) }
        #expect(!Self.shownText(view).contains(OnboardingStrings.computerUseHelperVersionMismatch))
        model.finish(completed: true)
    }

    static func shownText(_ view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField, !field.isHiddenOrHasHiddenAncestor { found.append(field.stringValue) }
        for child in view.subviews { found += shownText(child) }
        return found
    }

    @Test func closingTheTileOrTheFlowEndsTheHelp() {
        let source = MockComputerUsePermissionSource()
        let services = MockOnboardingServices()
        services.computerUseSource = source
        let model = OnboardingModel(services: services, start: .computerUse)
        model.stepDidAppear()
        model.computerUse.allow(.accessibility)
        model.computerUse.dismissHelper()
        #expect(model.computerUse.helping == nil)
        model.computerUse.allow(.accessibility)
        model.finish(completed: true)
        #expect(model.computerUse.helping == nil)
    }

    @Test func everyRowHasTextAndASymbol() {
        for pane in ComputerUsePermissionPane.allCases {
            #expect(!OnboardingStrings.computerUseName(pane).isEmpty && !OnboardingStrings.computerUseDetail(pane).isEmpty)
            #expect(NSImage(systemSymbolName: ComputerUseStepView.symbol(pane), accessibilityDescription: nil) != nil)
        }
        #expect(Set(ComputerUsePermissionPane.allCases.map(OnboardingStrings.computerUseName)).count == 2)
    }

    /// Each row's number presses its Allow, as clicking does; a granted row's key does nothing.
    @Test func eachRowsNumberKeyAllowsIt() async throws {
        let source = MockComputerUsePermissionSource(current: ComputerUsePermissions(accessibility: true, screenRecording: false))
        let services = MockOnboardingServices()
        services.computerUseSource = source
        let model = OnboardingModel(services: services, start: .computerUse)
        model.stepDidAppear()
        await settle { model.computerUse.permissions.accessibility }
        let view = ComputerUseStepView(model: model.computerUse)
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
        view.layoutSubtreeIfNeeded()
        #expect(ComputerUsePermissionPane.allCases.indices.map(ComputerUseStepView.key) == ["1", "2"])
        func press(_ key: String) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                      context: nil, characters: key, charactersIgnoringModifiers: key,
                                                      isARepeat: false, keyCode: 0))
            return view.performKeyEquivalent(with: event)
        }
        #expect(try press("2"))
        #expect(source.opened == [.screenRecording] && model.computerUse.helping == .screenRecording)
        _ = try press("1")
        #expect(source.opened == [.screenRecording], "accessibility is already granted")
        model.finish(completed: true)
    }
}
