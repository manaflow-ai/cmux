import Darwin
import os

/// Owns raw execution descriptors and transfers or closes them exactly once.
final class SudoSpawnedProcessIO: Sendable {
    struct Descriptors: Sendable {
        var input: Int32
        var output: Int32
        var outputFile: Int32
    }

    // A short lock provides synchronous compare-and-take ownership for raw descriptors.
    private let descriptors: OSAllocatedUnfairLock<Descriptors>

    init(input: Int32, output: Int32, outputFile: Int32) {
        descriptors = OSAllocatedUnfairLock(
            initialState: Descriptors(
                input: input,
                output: output,
                outputFile: outputFile
            )
        )
    }

    func takeDescriptors() -> Descriptors {
        descriptors.withLock { descriptors in
            let taken = descriptors
            descriptors = Descriptors(input: -1, output: -1, outputFile: -1)
            return taken
        }
    }

    func close() {
        let taken = takeDescriptors()
        for descriptor in Set([taken.input, taken.output, taken.outputFile])
        where descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    deinit {
        close()
    }
}
