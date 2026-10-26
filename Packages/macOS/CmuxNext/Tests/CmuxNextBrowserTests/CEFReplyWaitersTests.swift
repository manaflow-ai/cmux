@testable import CmuxNextBrowser
import Testing

/// Chromium Host REPLY frames awaited by token (`CEFHostReplies`, task p01-process-018) and read by
/// `CEFHostReplyFields`: the golden body that ChromiumHost/src/chromium_host_tlv.h's TlvWriter
/// encodes, replies before and after the await, replies resolved off the main thread, malformed
/// shapes, the deadline, cancellation and the host's exit.
@Suite(.timeLimit(.minutes(1))) struct CEFReplyWaitersTests {
    /// TlvWriter: I32(-2), Str(NULL), Str("hé"), I32Array({3, -1}), I64(0x0102030405060708),
    /// F64(1.5), StrList({"a", NULL}), Bytes(NULL), as EncodeFields writes them.
    static let golden = hexBytes(
        "01000400feffffff050100000500030068c3a90400080003000000ffffffff0200080008070605040302010300"
            + "0800000000000000f83f010004000200000005000100610501000004010000")

    nonisolated static func hexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    /// One field as EncodeFields writes it: type, tag (1 = NULL), u16 length, payload.
    nonisolated static func field(_ type: UInt8, _ payload: [UInt8], null: Bool = false) -> [UInt8] {
        [type, null ? 1 : 0, UInt8(payload.count & 0xff), UInt8(payload.count >> 8)] + payload
    }

    nonisolated static func int32(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return field(1, [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: bits >> $0) })
    }

    nonisolated static func string(_ text: String) -> [UInt8] {
        field(5, Array(text.utf8))
    }

    /// The reply error `body` throws, nil when it returns.
    static func failure<T>(of body: () throws -> T) -> CEFHostReplyError? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? CEFHostReplyError
        }
    }

    static func awaitedFailure<T>(of body: () async throws -> T) async -> CEFHostReplyError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? CEFHostReplyError
        }
    }

    /// Resolves `tokens` from a thread of the shared pool, as the reply callback does from the
    /// control channel; each answer is the token times ten.
    @concurrent nonisolated static func resolveOffMain(_ replies: CEFHostReplies, tokens: [UInt32]) async -> [Bool] {
        tokens.map { replies.resolve($0, fields: int32(Int32($0) * 10)) }
    }

    @Test func readsTheGoldenBodyOfTheCxxWriter() throws {
        var fields = try CEFHostReplyFields(encoded: Self.golden)
        let result = try fields.int32()
        let null = try fields.string()
        let text = try fields.string()
        let ids = try fields.int32Array()
        let wide = try fields.int64()
        let real = try fields.double()
        let list = try fields.strings()
        let buffer = try fields.bytes()
        #expect(result == -2)
        #expect(null == nil)
        #expect(text == "hé")
        #expect(ids == [3, -1])
        #expect(wide == 0x0102030405060708)
        #expect(real == 1.5)
        #expect(list == ["a", ""])
        #expect(buffer.isEmpty)
        #expect(fields.isAtEnd)
        try fields.finish()
    }

    @Test func refusesBodiesThatAreNotTheReplyShape() {
        // A header past the end, a field past the end, an unknown type, a fixed field of the wrong size.
        let shortHeader = Self.failure { try CEFHostReplyFields(encoded: [1, 0, 4]) }
        let shortField = Self.failure { try CEFHostReplyFields(encoded: [1, 0, 4, 0, 1]) }
        let unknownType = Self.failure { try CEFHostReplyFields(encoded: Self.field(9, [])) }
        let wrongSize = Self.failure { try CEFHostReplyFields(encoded: Self.field(1, [1, 2, 3])) }
        // A read of the wrong type, past the end, of text that is not UTF-8, of a partial int array.
        let wrongType = Self.failure {
            var fields = try CEFHostReplyFields(encoded: Self.int32(1))
            return try fields.string()
        }
        let pastTheEnd = Self.failure {
            var fields = try CEFHostReplyFields(encoded: [])
            return try fields.int32()
        }
        let notUTF8 = Self.failure {
            var fields = try CEFHostReplyFields(encoded: Self.field(5, [0xff]))
            return try fields.string()
        }
        let partialArray = Self.failure {
            var fields = try CEFHostReplyFields(encoded: Self.field(4, [1, 2, 3, 4, 5]))
            return try fields.int32Array()
        }
        // A list longer than the fields after its count, and a field left unread.
        let longList = Self.failure {
            var fields = try CEFHostReplyFields(encoded: Self.int32(3) + Self.string("a"))
            return try fields.strings()
        }
        let leftover = Self.failure {
            var fields = try CEFHostReplyFields(encoded: Self.int32(1) + Self.int32(2))
            _ = try fields.int32()
            try fields.finish()
        }
        let all = [shortHeader, shortField, unknownType, wrongSize, wrongType, pastTheEnd, notUTF8, partialArray,
                   longList, leftover]
        #expect(all.count == 10)
        #expect(all.allSatisfy { $0 == .malformed })
    }

    @Test func keepsAReplyThatComesBeforeTheAwait() async throws {
        let replies = CEFHostReplies()
        replies.expect(7)
        #expect(replies.resolve(7, fields: Self.int32(1) + Self.string("x")))
        let value = try await replies.reply(to: 7, label: "content setting", timeout: .seconds(30)) {
            (fields: inout CEFHostReplyFields) throws(CEFHostReplyError) -> ReplyPair in
            ReplyPair(result: try fields.int32(), text: try fields.string())
        }
        #expect(value == ReplyPair(result: 1, text: "x"))
        #expect(replies.count == 0)
    }

    @Test func dropsATokenNobodyExpects() {
        let replies = CEFHostReplies()
        #expect(!replies.resolve(9, fields: Self.int32(1)))
        #expect(replies.count == 0)
    }

    @Test func eachTokenResumesItsOwnWaiterWhenRepliesComeOffMainInAnyOrder() async throws {
        let replies = CEFHostReplies()
        let tokens = (1...50).map { UInt32($0) }
        for token in tokens { replies.expect(token) }
        let values = try await withThrowingTaskGroup(of: (UInt32, Int32).self) { group in
            for token in tokens {
                group.addTask {
                    (token, try await replies.reply(to: token, as: Int32.self, label: "renderer ids", timeout: .seconds(30)))
                }
            }
            let resolved = await Self.resolveOffMain(replies, tokens: tokens.reversed())
            #expect(resolved.allSatisfy { $0 })
            var values: [UInt32: Int32] = [:]
            for try await (token, value) in group { values[token] = value }
            return values
        }
        #expect(values.count == 50)
        #expect(tokens.allSatisfy { values[$0] == Int32($0) * 10 })
        #expect(replies.count == 0)
    }

    @Test func aReplyWithTheWrongShapeFailsItsWaiter() async {
        let replies = CEFHostReplies()
        replies.expect(5)
        replies.resolve(5, fields: Self.int32(1) + Self.int32(2))  // one value expected, two came
        let error = await Self.awaitedFailure { try await replies.reply(to: 5, as: Int32.self, label: "try close", timeout: .seconds(30)) }
        #expect(error == .malformed)
    }

    @Test func aNullStringResultIsNil() async throws {
        let replies = CEFHostReplies()
        replies.expect(6)
        replies.resolve(6, fields: Self.field(5, [], null: true))
        let value = try await replies.reply(to: 6, as: String?.self, label: "pref get", timeout: .seconds(30))
        #expect(value == nil)
    }

    @Test func aReplyThatNeverComesTimesOut() async {
        let replies = CEFHostReplies()
        replies.expect(3)
        let error = await Self.awaitedFailure { try await replies.reply(to: 3, as: Int32.self, label: "ssl status", timeout: .zero) }
        #expect(error == .timedOut("ssl status", .zero))
        #expect(replies.count == 0)
        #expect(!replies.resolve(3, fields: Self.int32(1)))  // late: nobody waits any more
    }

    @Test func aCancelledWaitFailsAndLeavesNoSlot() async {
        let replies = CEFHostReplies()
        replies.expect(4)
        let wait = Task { try await replies.reply(to: 4, as: Int32.self, label: "context proxy state", timeout: .seconds(30)) }
        wait.cancel()
        let error = await Self.awaitedFailure { try await wait.value }
        #expect(error == .cancelled)
        #expect(replies.count == 0)
    }

    @Test func theHostsExitFailsEveryTokenNotAnsweredYet() async throws {
        let replies = CEFHostReplies()
        replies.expect(1)
        replies.expect(2)
        replies.expect(3)
        replies.resolve(3, fields: Self.int32(30))  // answered before the exit: still the answer
        let waiting = Task { try await replies.reply(to: 2, as: Int32.self, label: "bookmarks sync", timeout: .seconds(30)) }
        replies.failAll(.hostGone)
        let first = await Self.awaitedFailure { try await replies.reply(to: 1, as: Int32.self, label: "try close", timeout: .seconds(30)) }
        #expect(first == .hostGone)
        let second = await Self.awaitedFailure { try await waiting.value }
        #expect(second == .hostGone)
        let third = try await replies.reply(to: 3, as: Int32.self, label: "content setting", timeout: .seconds(30))
        #expect(third == 30)
        #expect(replies.count == 0)
    }
}

/// A two-value reply (a result and an out-parameter) for the typed-closure form.
private nonisolated struct ReplyPair: Equatable, Sendable {
    let result: Int32
    let text: String?
}
