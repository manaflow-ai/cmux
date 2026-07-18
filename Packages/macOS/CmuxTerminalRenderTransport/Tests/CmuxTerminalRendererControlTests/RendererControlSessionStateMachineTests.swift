import CmuxTerminalRendererControl
import Testing

@Suite
struct RendererControlSessionStateMachineTests {
    private let fixture = RendererControlTestFixture()

    @Test
    func bootstrapReadyAttachSceneReleaseAndDetachAreOrdered() throws {
        var state = RendererControlSessionStateMachine()
        try state.accept(fixture.envelope(.bootstrap(fixture.bootstrap()), sequence: 1))
        try state.accept(fixture.envelope(.ready(fixture.ready()), sequence: 1))
        try state.accept(fixture.envelope(
            .upsertPresentation(fixture.attachment()),
            sequence: 2
        ))
        try state.accept(fixture.envelope(.semanticScene(fixture.scene()), sequence: 3))
        try state.accept(fixture.envelope(.frameRelease(fixture.release()), sequence: 4))
        try state.accept(fixture.envelope(
            .presentationReady(fixture.presentationReady()),
            sequence: 2
        ))
        try state.accept(fixture.envelope(
            .needsFullScene(fixture.needsFullScene()),
            sequence: 3
        ))
        #expect(state.presentationCount == 1)
        try state.accept(fixture.envelope(
            .removePresentation(fixture.removal()),
            sequence: 5
        ))
        #expect(state.presentationCount == 0)
        try state.accept(fixture.envelope(
            .presentationRemoved(fixture.presentationRemoved()),
            sequence: 4
        ))
        #expect(throws: RendererControlError.invalidTransition) {
            try state.accept(fixture.envelope(.semanticScene(fixture.scene()), sequence: 6))
        }
        #expect(state.isTerminal)
    }

    @Test
    func presentationReadyRequiresCurrentExactSceneFence() throws {
        var beforeScene = RendererControlSessionStateMachine()
        try beforeScene.accept(fixture.envelope(.bootstrap(fixture.bootstrap()), sequence: 1))
        try beforeScene.accept(fixture.envelope(.ready(fixture.ready()), sequence: 1))
        try beforeScene.accept(fixture.envelope(
            .upsertPresentation(fixture.attachment()),
            sequence: 2
        ))
        #expect(throws: RendererControlError.invalidTransition) {
            try beforeScene.accept(fixture.envelope(
                .presentationReady(fixture.presentationReady()),
                sequence: 2
            ))
        }

        var wrongScene = RendererControlSessionStateMachine()
        try wrongScene.accept(fixture.envelope(.bootstrap(fixture.bootstrap()), sequence: 1))
        try wrongScene.accept(fixture.envelope(.ready(fixture.ready()), sequence: 1))
        try wrongScene.accept(fixture.envelope(
            .upsertPresentation(fixture.attachment()),
            sequence: 2
        ))
        try wrongScene.accept(fixture.envelope(.semanticScene(fixture.scene()), sequence: 3))
        #expect(throws: RendererControlError.invalidTransition) {
            try wrongScene.accept(fixture.envelope(
                .presentationReady(fixture.presentationReady(canonicalSequence: 19)),
                sequence: 2
            ))
        }
    }

    @Test
    func exactReleaseForRetiredGenerationRemainsValid() throws {
        var state = RendererControlSessionStateMachine()
        try state.accept(fixture.envelope(.bootstrap(fixture.bootstrap()), sequence: 1))
        try state.accept(fixture.envelope(.ready(fixture.ready()), sequence: 1))
        try state.accept(fixture.envelope(
            .upsertPresentation(fixture.attachment()),
            sequence: 2
        ))
        try state.accept(fixture.envelope(
            .upsertPresentation(fixture.attachment(generation: 2)),
            sequence: 3
        ))
        try state.accept(fixture.envelope(.frameRelease(fixture.release()), sequence: 4))
        #expect(!state.isTerminal)
    }

    @Test
    func bootstrapMustBeFirstAndReadyMustPrecedeAttach() throws {
        var withoutBootstrap = RendererControlSessionStateMachine()
        #expect(throws: RendererControlError.invalidTransition) {
            try withoutBootstrap.accept(fixture.envelope(.ready(fixture.ready()), sequence: 1))
        }

        var withoutReady = RendererControlSessionStateMachine()
        try withoutReady.accept(fixture.envelope(.bootstrap(fixture.bootstrap()), sequence: 1))
        #expect(throws: RendererControlError.invalidTransition) {
            try withoutReady.accept(fixture.envelope(
                .upsertPresentation(fixture.attachment()),
                sequence: 2
            ))
        }
    }

    @Test
    func crossPresentationReleaseIsRejected() throws {
        var state = RendererControlSessionStateMachine()
        try state.accept(fixture.envelope(.bootstrap(fixture.bootstrap()), sequence: 1))
        try state.accept(fixture.envelope(.ready(fixture.ready()), sequence: 1))
        try state.accept(fixture.envelope(
            .upsertPresentation(fixture.attachment()),
            sequence: 2
        ))
        try state.accept(fixture.envelope(
            .upsertPresentation(fixture.attachment(
                terminalID: fixture.terminalB,
                presentationID: fixture.presentationB
            )),
            sequence: 3
        ))
        let crossed = try fixture.release(
            terminalID: fixture.terminalA,
            presentationID: fixture.presentationB
        )
        #expect(throws: RendererControlError.invalidTransition) {
            try state.accept(fixture.envelope(.frameRelease(crossed), sequence: 4))
        }
    }

    @Test
    func shutdownAndFatalAreTerminal() throws {
        var shutdown = RendererControlSessionStateMachine()
        try shutdown.accept(fixture.envelope(.bootstrap(fixture.bootstrap()), sequence: 1))
        try shutdown.accept(fixture.envelope(.shutdown, sequence: 2))
        #expect(shutdown.isTerminal)
        #expect(throws: RendererControlError.invalidTransition) {
            try shutdown.accept(fixture.envelope(.shutdown, sequence: 3))
        }

        var fatal = RendererControlSessionStateMachine()
        try fatal.accept(fixture.envelope(.bootstrap(fixture.bootstrap()), sequence: 1))
        try fatal.accept(fixture.envelope(
            .fatal(RendererFatal(code: .internalInvariant, diagnostic: "failed")),
            sequence: 1
        ))
        #expect(fatal.isTerminal)
    }

    @Test
    func detachedGenerationCannotBeReplayed() throws {
        var state = RendererControlSessionStateMachine()
        try state.accept(fixture.envelope(.bootstrap(fixture.bootstrap()), sequence: 1))
        try state.accept(fixture.envelope(.ready(fixture.ready()), sequence: 1))
        try state.accept(fixture.envelope(
            .upsertPresentation(fixture.attachment()),
            sequence: 2
        ))
        try state.accept(fixture.envelope(
            .removePresentation(fixture.removal()),
            sequence: 3
        ))
        #expect(throws: RendererControlError.invalidTransition) {
            try state.accept(fixture.envelope(
                .upsertPresentation(fixture.attachment()),
                sequence: 4
            ))
        }
    }

    @Test
    func removalAcknowledgementMustMatchOnePendingLifetimeExactly() throws {
        var state = RendererControlSessionStateMachine()
        try state.accept(fixture.envelope(.bootstrap(fixture.bootstrap()), sequence: 1))
        try state.accept(fixture.envelope(.ready(fixture.ready()), sequence: 1))
        try state.accept(fixture.envelope(
            .upsertPresentation(fixture.attachment()),
            sequence: 2
        ))
        try state.accept(fixture.envelope(
            .removePresentation(fixture.removal()),
            sequence: 3
        ))
        try state.accept(fixture.envelope(
            .presentationRemoved(fixture.presentationRemoved()),
            sequence: 2
        ))
        #expect(throws: RendererControlError.invalidTransition) {
            try state.accept(fixture.envelope(
                .presentationRemoved(fixture.presentationRemoved()),
                sequence: 3
            ))
        }
        #expect(state.isTerminal)
    }

    @Test
    func exactRemovalCanBeRetransmittedAfterLostAcknowledgement() throws {
        var state = RendererControlSessionStateMachine()
        try state.accept(fixture.envelope(.bootstrap(fixture.bootstrap()), sequence: 1))
        try state.accept(fixture.envelope(.ready(fixture.ready()), sequence: 1))
        try state.accept(fixture.envelope(
            .upsertPresentation(fixture.attachment()),
            sequence: 2
        ))
        try state.accept(fixture.envelope(
            .removePresentation(fixture.removal()),
            sequence: 3
        ))
        try state.accept(fixture.envelope(
            .presentationRemoved(fixture.presentationRemoved()),
            sequence: 2
        ))

        try state.accept(fixture.envelope(
            .removePresentation(fixture.removal()),
            sequence: 4
        ))
        try state.accept(fixture.envelope(
            .presentationRemoved(fixture.presentationRemoved()),
            sequence: 3
        ))

        #expect(!state.isTerminal)
        #expect(state.presentationCount == 0)
    }

    @Test
    func semanticSceneSequencesCannotRegress() throws {
        var state = RendererControlSessionStateMachine()
        try state.accept(fixture.envelope(.bootstrap(fixture.bootstrap()), sequence: 1))
        try state.accept(fixture.envelope(.ready(fixture.ready()), sequence: 1))
        try state.accept(fixture.envelope(
            .upsertPresentation(fixture.attachment()),
            sequence: 2
        ))
        try state.accept(fixture.envelope(.semanticScene(fixture.scene()), sequence: 3))
        #expect(throws: RendererControlError.invalidTransition) {
            try state.accept(fixture.envelope(
                .semanticScene(fixture.scene(canonicalSequence: 19)),
                sequence: 4
            ))
        }
    }
}
