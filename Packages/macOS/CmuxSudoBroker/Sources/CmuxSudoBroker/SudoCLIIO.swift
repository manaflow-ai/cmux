import Foundation

struct SudoCLIIO {
    let readStandardInput: (_ maximumBytes: Int) throws -> Data
    let writeStandardOutput: (Data) throws -> Void
    let writeStandardError: (String) -> Void

    static var live: SudoCLIIO {
        let reader = SudoBoundedInputReader()
        return SudoCLIIO(
            readStandardInput: { try reader.readStandardInput(maximumBytes: $0) },
            writeStandardOutput: { try FileHandle.standardOutput.write(contentsOf: $0) },
            writeStandardError: { message in
                try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
            }
        )
    }
}
