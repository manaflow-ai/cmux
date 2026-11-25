#if canImport(CmuxMobileLinkFFI)
import CmuxMobileChief
import CmuxMobileLinkFFI
import Foundation

// The Rust client of Auto chats (`cmux-mobile-link-ffi` `auto_chats.rs`) as the phone's
// ``AutoChatService``. Rust decides every request; Swift sends each one over the account's own
// Cloud path (``AccountCloud/autoChats(_:_:body:timeout:)``), which adds the bearer and the
// build space and sends nothing outside the Auto chat routes.

/// The app's HTTP path, as the Rust client asks for it.
final class AutoChatHTTP: AutoHttp, @unchecked Sendable {
    private let account: @Sendable () async -> AccountCloud?

    init(account: @escaping @Sendable () async -> AccountCloud?) {
        self.account = account
    }

    func send(request: AutoHttpRequest) async throws -> AutoHttpReply {
        guard let account = await account() else { throw AutoHttpError.Failed(message: "not signed in") }
        do {
            let reply = try await account.autoChats(request.method, request.path, body: request.body.map { Data($0.utf8) },
                                                    timeout: TimeInterval(request.timeoutMs) / 1000)
            return AutoHttpReply(status: UInt16(clamping: reply.status), body: String(decoding: reply.body, as: UTF8.self))
        } catch {
            throw AutoHttpError.Failed(message: "no answer")
        }
    }
}

/// A Rust error as the phone's.
private func autoChatFailure(_ error: any Error) -> AutoChatFailure {
    guard let error = error as? AutoChatError else { return .unreachable }
    switch error {
    case .Unreachable: return .unreachable
    case let .Refused(status, code, _): return .refused(status: Int(status), code: code)
    case .Unreadable: return .unreadable
    }
}

/// The account's Auto chats through the Rust client.
struct FFIAutoChats: AutoChatService {
    private let chats: AutoChats

    init(account: @escaping @Sendable () async -> AccountCloud?) {
        chats = AutoChats(http: AutoChatHTTP(account: account))
    }

    func list() async throws -> String {
        do { return try await chats.list() } catch { throw autoChatFailure(error) }
    }

    func hasMachine() async throws -> Bool {
        do { return try await chats.hasMachine() } catch { throw autoChatFailure(error) }
    }

    func start(remote: String, branch: String, messageID: String, text: String) async throws -> String {
        do {
            return try await chats.start(remote: remote, branch: branch, messageId: messageID, text: text)
        } catch {
            throw autoChatFailure(error)
        }
    }

    func line(id: String) -> any AutoChatLine {
        FFIAutoChatLine(chat: chats.chat(id: id))
    }
}

/// One open chat through the Rust client.
final class FFIAutoChatLine: AutoChatLine {
    private let chat: AutoChat

    init(chat: AutoChat) {
        self.chat = chat
    }

    func next() async throws -> String {
        do { return try await chat.next() } catch { throw autoChatFailure(error) }
    }

    func send(messageID: String, text: String) async throws -> String {
        do { return try await chat.send(messageId: messageID, text: text) } catch { throw autoChatFailure(error) }
    }

    func keep(_ keepInCloud: Bool) async throws -> String {
        do { return try await chat.keep(keepInCloud: keepInCloud) } catch { throw autoChatFailure(error) }
    }

    func close() {
        chat.close()
    }
}

extension AutoChatsModel {
    /// The signed-in account's Auto chats, over its own Cloud path.
    public static func live() -> AutoChatsModel {
        AutoChatsModel(service: FFIAutoChats(account: { await ChiefSources.shared.account }))
    }
}
#endif
