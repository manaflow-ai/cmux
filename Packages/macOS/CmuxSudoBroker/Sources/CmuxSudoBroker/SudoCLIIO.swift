import Foundation

struct SudoCLIIO {
    let readStandardInput: () throws -> Data
    let writeStandardOutput: (Data) throws -> Void
    let writeStandardError: (String) -> Void

    static var live: SudoCLIIO {
        SudoCLIIO(
            readStandardInput: { try FileHandle.standardInput.readToEnd() ?? Data() },
            writeStandardOutput: { try FileHandle.standardOutput.write(contentsOf: $0) },
            writeStandardError: { message in
                try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
            }
        )
    }
}
