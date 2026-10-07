public import Foundation

/// Splits a byte-stream carrier into records. Holds at most one partial
/// record; consumed bytes are dropped once per `push`, so many small records
/// in one chunk cost linear time. After an error every call throws it again.
public struct RecordDeframer: Sendable {
    private var buffer = Data()
    private var failure: RecordError?

    public init() {}

    public mutating func push(_ chunk: Data) throws(RecordError) -> [StreamRecord] {
        if let failure { throw failure }
        buffer.append(chunk)
        var records: [StreamRecord] = []
        var at = 0
        do throws(RecordError) {
            while buffer.count - at >= StreamRecord.lengthPrefix {
                let length = Int(buffer.littleEndian(at: at, count: 4))
                guard length <= StreamRecord.maxRecord else { throw RecordError(.tooLarge, "record length \(length) above max_record") }
                guard length >= StreamRecord.headerLength else { throw RecordError(.badLength, "record length \(length) below the header") }
                let start = at + StreamRecord.lengthPrefix
                guard buffer.count - start >= length else { break }
                let base = buffer.startIndex
                records.append(try StreamRecord(decoding: Data(buffer[(base + start)..<(base + start + length)])))
                at = start + length
            }
        } catch {
            failure = error
            buffer = Data()
            throw error
        }
        buffer = buffer.tail(from: at)
        return records
    }
}
