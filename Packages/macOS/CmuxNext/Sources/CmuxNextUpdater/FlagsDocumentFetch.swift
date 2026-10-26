public import Foundation

/// Why a fetched flags document was not handed on.
nonisolated public enum FlagsDocumentRejection: Error, Sendable, Equatable {
    /// The document or its signature could not be fetched (offline, HTTP error).
    case transport(String)
    /// The signature file was empty or not text.
    case missingSignature
    /// The signature does not verify with the notes' content key.
    case badSignature
}

/// One conditional fetch of the signed `notes/flags.json` (p12-perf-process-093),
/// next to the release notes, with their content key: no second URL or key.
/// Chrome's variations seed fetch is the model
/// (components/variations/service/variations_service.cc: `If-None-Match`, a 304
/// keeps the stored seed; variations_seed_store.cc verifies the signature
/// before storing). There is no timer and no retry: the caller runs it once a launch.
nonisolated public struct FlagsDocumentFetch: Sendable {
    public static let fileName = "flags.json"

    public let documentURL: URL
    public let signatureURL: URL
    let publicKey: String
    private let fetcher: any ConditionalFetching

    /// What one run did.
    public enum Outcome: Sendable, Equatable {
        case disabledByPolicy
        /// The server's copy is the one received last (304, or the same ETag).
        case notModified
        /// A verified document went to the receiver.
        case received
        /// The feed publishes no flags document (HTTP 404; the stable feed today).
        case notPublished
        case rejected(FlagsDocumentRejection)
    }

    init(notesBase: URL, publicKey: String, fetcher: any ConditionalFetching) {
        documentURL = notesBase.appending(path: Self.fileName)
        signatureURL = notesBase.appending(path: Self.fileName + ".sig")
        self.publicKey = publicKey
        self.fetcher = fetcher
    }

    /// Off the main actor: the policy read, both fetches, the verification and the hand-off.
    @concurrent
    public func run(into receiver: any FlagsDocumentReceiving, policy: FlagsFetchPolicy) async -> Outcome {
        if policy.disablesFetch { return .disabledByPolicy }
        let lastETag = await receiver.lastETag()
        let data: Data
        let etag: String?
        do {
            switch try await fetcher.fetch(documentURL, ifNoneMatch: lastETag) {
            case .notModified:
                return .notModified
            case .fetched(let fetched, let fetchedETag):
                if let fetchedETag, fetchedETag == lastETag { return .notModified }
                data = fetched
                etag = fetchedETag
            }
        } catch ConditionalFetchError.http(status: 404) {
            return .notPublished
        } catch {
            return .rejected(.transport(String(describing: error)))
        }
        let signatureData: Data
        do {
            guard case .fetched(let fetched, _) = try await fetcher.fetch(signatureURL, ifNoneMatch: nil) else {
                return .rejected(.missingSignature)
            }
            signatureData = fetched
        } catch {
            return .rejected(.transport(String(describing: error)))
        }
        guard let signature = String(data: signatureData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !signature.isEmpty else { return .rejected(.missingSignature) }
        guard ContentSignature.verify(data, signature: signature, publicKey: publicKey) else { return .rejected(.badSignature) }
        await receiver.receive(VerifiedFlagsDocument(data: data, signature: signature, etag: etag))
        return .received
    }
}

extension FlagsDocumentFetch.Outcome {
    /// One line for the update log.
    public var logText: String {
        switch self {
        case .disabledByPolicy: "off (managed policy \(FlagsFetchPolicy.key))"
        case .notModified: "not modified"
        case .received: "received; applies at next launch"
        case .notPublished: "not published by this feed"
        case .rejected(.transport(let reason)): "fetch failed: \(reason)"
        case .rejected(.missingSignature): "rejected: no signature"
        case .rejected(.badSignature): "rejected: signature does not verify"
        }
    }
}
