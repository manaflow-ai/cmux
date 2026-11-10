public import CmuxNextPages
public import CmuxNextSettings
import CmuxNextCompat
import Foundation
import UniformTypeIdentifiers

/// The files the app offers the Messages page's composer (``HomeComposerIntake``): each by a token
/// the page reads its bytes with, in frames, while it answers `home.messages.attach`
/// (`cmux.home.messages.attachments.intake.read {token, offset, length}` -> `{data}`, base64). A
/// token names one file the app chose (the person's pick, a path the CLI gave, a quote or a
/// highlight the app wrote), so the page reads nothing else; tokens go when the call ends.
@MainActor
public final class HomeMessagesIntake {
    /// The ops this answers, after `cmux.home.messages.`.
    public static let prefix = "attachments.intake."
    /// The largest frame a read answers (the page reads 3 MB frames, host.ts).
    static let maxReadBytes = 4 * 1024 * 1024

    private var offers: [String: URL] = [:]

    public init() {}

    /// Offers `urls` for one call: `{token, name, mimeType, byteCount}` each; nil when one is not a
    /// regular file (the caller says which path names none).
    func offer(_ urls: [URL]) async -> [JSONValue]? {
        var out: [JSONValue] = []
        var tokens: [String] = []
        for url in urls {
            guard let size = await Self.fileSize(url) else {
                withdraw(tokens)
                return nil
            }
            let token = UUID().uuidString
            tokens.append(token)
            offers[token] = url
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
            out.append(.object(["token": .string(token), "name": .string(url.lastPathComponent),
                                "mimeType": .string(type), "byteCount": .number(Double(size))]))
        }
        return out
    }

    /// The call ended: its files are no longer offered.
    func withdraw(_ tokens: [String]) {
        for token in tokens { offers[token] = nil }
    }

    /// Answers `name` (the op after `cmux.home.messages.`), or nil when it is not one of these.
    public func call(_ name: String, _ fields: [String: JSONValue]) async throws -> JSONValue? {
        guard name == Self.prefix + "read" else { return nil }
        guard let token = fields["token"]?.stringValue, let url = offers[token] else {
            throw PageError.invalidParams("token names no offered file")
        }
        guard let offset = HomeMessagesKept.count(fields["offset"]), let length = HomeMessagesKept.count(fields["length"]),
              length <= Self.maxReadBytes else {
            throw PageError.invalidParams("read needs offset and length")
        }
        do {
            let data = try await HomeMessagesAttachmentDrafts.read(url, offset: UInt64(offset), length: length)
            return .object(["data": .string(data.base64EncodedString())])
        } catch {
            throw PageError.invalidParams("\(error)")
        }
    }

    /// A regular file's size (a stat off the main actor); nil for anything else.
    @concurrent nonisolated static func fileSize(_ url: URL) async -> Int? {
        guard let values = try? url.blockingResourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { return nil }
        return values.fileSize
    }
}
