public import Foundation

/// Why a fetched flags document was not handed on.
nonisolated public enum FlagsDocumentRejection: Error, Sendable, Equatable {
    /// The document or its signature could not be fetched (offline, HTTP error).
    case transport(ConditionalFetchError)
    /// The signature file was empty or not text.
    case missingSignature
    /// The signature does not verify with the notes' content key.
    case badSignature
}

/// One conditional fetch of the signed `notes/flags.json`,
/// next to the release notes, with their content key: no second URL or key.
/// Chrome's variations seed fetch is the model
/// (components/variations/service/variations_service.cc: `If-None-Match`, a 304
/// keeps the stored seed and still counts as a successful fetch;
/// variations_seed_store.cc verifies the signature before storing). There is no
/// timer and no retry: ``UpdaterService/start()`` runs it once a launch.
nonisolated public struct FlagsDocumentFetch: Sendable {
    public static let fileName = "flags.json"

    public let documentURL: URL
    public let signatureURL: URL
    let publicKey: String
    private let fetcher: any ConditionalFetching

    /// What one run did.
    nonisolated public enum Outcome: Sendable, Equatable {
        /// `DisableRemoteFeatureFlags` is forced: nothing was fetched, and no stored document may apply.
        case disabledByPolicy
        /// The server's copy is the one received last (304, or the same ETag).
        case notModified
        /// A verified document went to the receiver.
        case received
        /// The feed publishes no flags document (HTTP 404; the stable feed today).
        case notPublished
        case rejected(FlagsDocumentRejection)
    }

    /// How a run counts for the fetch-failure streak (Chrome's `SafeSeedManager`,
    /// components/variations/service/safe_seed_manager.cc).
    nonisolated public enum Attempt: Sendable, Equatable {
        /// The server answered with a usable state: a new document, a 304, or none published.
        case succeeded
        /// The fetch or the signature failed.
        case failed
        /// The policy turned the fetch off.
        case notAttempted
    }

    init(notesBase: URL, publicKey: String, fetcher: any ConditionalFetching) {
        documentURL = notesBase.appending(path: Self.fileName)
        signatureURL = notesBase.appending(path: Self.fileName + ".sig")
        self.publicKey = publicKey
        self.fetcher = fetcher
    }

    /// Off the main actor: both fetches, the verification and the hand-off. The
    /// receiver hears every outcome through ``FlagsDocumentReceiving/fetchCompleted(_:)``,
    /// after ``FlagsDocumentReceiving/receive(_:)`` for a new document.
    @concurrent
    public func run(into receiver: any FlagsDocumentReceiving, policy: FlagsFetchPolicy) async -> Outcome {
        let outcome: Outcome
        if policy.disablesRemoteFlags {
            outcome = .disabledByPolicy
        } else {
            outcome = await fetchAndVerify(into: receiver)
        }
        await receiver.fetchCompleted(outcome)
        return outcome
    }

    @concurrent
    private func fetchAndVerify(into receiver: any FlagsDocumentReceiving) async -> Outcome {
        let lastETag = await receiver.lastETag()
        let data: Data
        let etag: String?
        do throws(ConditionalFetchError) {
            switch try await fetcher.fetch(documentURL, ifNoneMatch: lastETag) {
            case .notModified:
                return .notModified
            case .fetched(let fetched, let fetchedETag):
                if let fetchedETag, fetchedETag == lastETag { return .notModified }
                data = fetched
                etag = fetchedETag
            }
        } catch {
            return error == .http(status: 404) ? .notPublished : .rejected(.transport(error))
        }
        let signatureData: Data
        do throws(ConditionalFetchError) {
            guard case .fetched(let fetched, _) = try await fetcher.fetch(signatureURL, ifNoneMatch: nil) else {
                return .rejected(.missingSignature)
            }
            signatureData = fetched
        } catch {
            return .rejected(.transport(error))
        }
        guard let signature = String(data: signatureData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !signature.isEmpty else { return .rejected(.missingSignature) }
        guard ContentSignature.verify(data, signature: signature, publicKey: publicKey) else { return .rejected(.badSignature) }
        await receiver.receive(VerifiedFlagsDocument(data: data, signature: signature, etag: etag))
        return .received
    }
}

nonisolated extension FlagsDocumentFetch.Outcome {
    /// How this run counts for the fetch-failure streak.
    public var attempt: FlagsDocumentFetch.Attempt {
        switch self {
        case .disabledByPolicy: .notAttempted
        case .notModified, .received, .notPublished: .succeeded
        case .rejected: .failed
        }
    }

    /// One line for the update log.
    public var logText: String {
        switch self {
        case .disabledByPolicy: "off (managed policy \(FlagsFetchPolicy.key))"
        case .notModified: "not modified"
        case .received: "received; applies at next launch"
        case .notPublished: "not published by this feed"
        case .rejected(.transport(let error)): "fetch failed: \(error)"
        case .rejected(.missingSignature): "rejected: no signature"
        case .rejected(.badSignature): "rejected: signature does not verify"
        }
    }
}
