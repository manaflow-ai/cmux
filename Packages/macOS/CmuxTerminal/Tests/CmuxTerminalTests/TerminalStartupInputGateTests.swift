import Foundation
import Testing
@testable import CmuxTerminal

@Suite
struct TerminalStartupInputGateTests {
    @Test("Only the shell that owns the queued restore can release it, once")
    func readinessOwnsDelivery() {
        var gate = TerminalStartupInputGate()
        let generation = UUID()
        gate.stage("cmux restore --surface\n", generation: generation)
        #expect(gate.takeForPrompt(generation: UUID()) == nil)
        #expect(gate.takeForPrompt(generation: generation) == "cmux restore --surface\n")
        #expect(gate.takeForPrompt(generation: generation) == nil)
        gate.stage("cmux restore --surface\n", generation: generation)
        #expect(gate.takeForPrompt(generation: generation) == nil)
    }

    @Test("Explicit input cancels startup bytes while the login shell is starting")
    func explicitInputCancelsDelivery() {
        var gate = TerminalStartupInputGate()
        let generation = UUID()
        gate.stage("cmux restore --surface\n", generation: generation)
        gate.cancel(generation: generation)
        #expect(gate.takeForPrompt(generation: generation) == nil)
    }

    @Test("Typing before native creation prevents a later startup payload from rearming")
    func inputBeforeStagingCancelsDelivery() {
        var gate = TerminalStartupInputGate()
        let generation = UUID()
        gate.cancel(generation: generation)
        gate.stage("cmux restore --surface\n", generation: generation)
        #expect(gate.takeForPrompt(generation: generation) == nil)
    }

    @Test("Input delivered directly at spawn cannot be delivered again by a later prompt")
    func directDeliveryConsumesGeneration() {
        var gate = TerminalStartupInputGate()
        let generation = UUID()
        gate.stage(nil, generation: generation)
        gate.stage("cmux restore --surface\n", generation: generation)
        #expect(gate.takeForPrompt(generation: generation) == nil)
    }

    @Test("A replaced runtime cannot receive the preceding shell's command")
    func replacementRejectsStalePrompt() {
        var gate = TerminalStartupInputGate()
        let old = UUID()
        let current = UUID()
        gate.stage("old\n", generation: old)
        gate.stage("current\n", generation: current)
        #expect(gate.takeForPrompt(generation: old) == nil)
        #expect(gate.takeForPrompt(generation: current) == "current\n")
    }
}
