import CmuxTerminalCore
import Testing

@Suite struct TerminalFontSizeDeltaTransformTests {
    @Test func matchesOrderedClampingAcrossBothBounds() {
        let sequences: [[Float32]] = [
            [1, -1],
            [-1, 1],
            [300, -1],
            [-300, 1],
            [1, 1, -1, -1, -1, 1],
            Array(repeating: [1, -1], count: 5_000).flatMap(\.self),
        ]
        let startingPoints: [Float32] = [1, 1.5, 13, 127.5, 254.5, 255]
        let policy = TerminalFontSizePolicy()

        for sequence in sequences {
            let transform = TerminalFontSizeDeltaTransform(
                orderedRuntimePointDeltas: sequence
            )
            for startingPoint in startingPoints {
                let expected = sequence.reduce(startingPoint) {
                    policy.clampedRuntimePoints($0 + $1)
                }
                #expect(transform.applying(to: startingPoint) == expected)
            }
        }
    }

    @Test func composingTransformsMatchesAppendingTheirSequences() {
        let firstDeltas: [Float32] = [300, -1, -1]
        let secondDeltas: [Float32] = [-300, 1, 1]
        var composed = TerminalFontSizeDeltaTransform(
            orderedRuntimePointDeltas: firstDeltas
        )
        composed.append(
            contentsOf: TerminalFontSizeDeltaTransform(
                orderedRuntimePointDeltas: secondDeltas
            )
        )
        let direct = TerminalFontSizeDeltaTransform(
            orderedRuntimePointDeltas: firstDeltas + secondDeltas
        )

        for startingPoint: Float32 in [1, 13, 127.5, 255] {
            #expect(composed.applying(to: startingPoint) == direct.applying(to: startingPoint))
        }
    }
}
