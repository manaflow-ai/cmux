public import CmuxNextBrowserCore
public import CmuxNextMobile
import Foundation

/// Platform read glue; no phone authorization or registrable-domain policy lives here.
@MainActor
public struct MobileSiteDataExporter {
    /// Engine-neutral state sampled around each asynchronous engine read.
    public struct Snapshot: Equatable {
        public let profileID: String
        public let incognito: Bool
        public let agentsProfile: Bool
        public let url: String?
        public let navigation: UInt64?
        public let isLoading: Bool

        public init(profileID: String, incognito: Bool, agentsProfile: Bool,
                    url: String?, navigation: UInt64?, isLoading: Bool) {
            self.profileID = profileID
            self.incognito = incognito
            self.agentsProfile = agentsProfile
            self.url = url
            self.navigation = navigation
            self.isLoading = isLoading
        }
    }

    private let snapshot: () -> Snapshot
    private let isCurrent: () -> Bool
    private let readCookies: () async throws -> [BrowserCookie]
    private let evaluate: (String, BrowserScriptWorld, BrowserScriptGesture) async throws -> BrowserJSValue

    /// The App supplies registry lookups and engine operations, without importing its UI engine here.
    /// `identity` returns the engine page object; replacements invalidate an in-flight export.
    public init<Model: AnyObject, Page>(model: Model?, currentModel: @escaping () -> Model?,
        page: @escaping (Model) -> Page?, identity: @escaping (Page) -> AnyObject,
        snapshot: @escaping (Model, Page) -> Snapshot,
        readCookies: @escaping (Page) async throws -> [BrowserCookie],
        evaluate: @escaping (Page, String, BrowserScriptWorld, BrowserScriptGesture) async throws -> BrowserJSValue) throws {
        guard let model, let source = page(model) else { throw MobileSiteDataExportError.unavailable }
        let sourceIdentity = identity(source)
        self.snapshot = { snapshot(model, source) }
        self.isCurrent = {
            guard currentModel() === model, let currentPage = page(model) else { return false }
            return identity(currentPage) === sourceIdentity
        }
        self.readCookies = { try await readCookies(source) }
        self.evaluate = { try await evaluate(source, $0, $1, $2) }
    }

    public func read(_ request: MobileHostSiteDataRequest) async throws -> MobileHostSiteData {
        let initial = snapshot()
        guard !initial.incognito, !initial.agentsProfile else { throw MobileSiteDataExportError.privateProfile }
        func checkPage() throws {
            guard isCurrent(), snapshot() == initial, initial.url == request.url, !initial.isLoading else {
                throw MobileSiteDataExportError.pageChanged
            }
        }
        try Task.checkCancellation()
        try checkPage()
        let cookies = try await readCookies()
        try Task.checkCancellation()
        try checkPage()
        // An isolated world prevents the page replacing Storage/JSON getters. No activation
        // is granted. Limits are checked before the result crosses the engine bridge; Rust
        // also checks the combined cookie/storage payload before handing it to the phone.
        let result = try await evaluate(Self.storageScript, .isolated, .cmux)
        try Task.checkCancellation()
        try checkPage()
        guard case .object(let object) = result,
              object["url"]?.stringValue == request.url,
              let origin = object["origin"]?.stringValue,
              case .array(let rawItems)? = object["items"] else { throw MobileSiteDataExportError.unavailable }
        var items: [[String]] = []
        for item in rawItems {
            guard case .array(let pair) = item, pair.count == 2,
                  let key = pair[0].stringValue, let value = pair[1].stringValue else {
                throw MobileSiteDataExportError.unavailable
            }
            items.append([key, value])
        }
        // The engine API reads a profile jar. Keep unrelated sites out of hostd's bounded
        // control line; Rust independently applies its authoritative site filter again.
        let siteCookies = cookies.filter {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return domain == request.site || domain.hasSuffix("." + request.site)
        }
        return try MobileHostSiteData(profileID: initial.profileID, agentsProfile: initial.agentsProfile,
            incognito: initial.incognito, cookies: siteCookies.map { cookie in
                let expiresMS: Int64?
                if let expiry = cookie.expires {
                    guard let milliseconds = Int64(exactly: (expiry.timeIntervalSince1970 * 1000).rounded(.towardZero)) else {
                        throw MobileSiteDataExportError.unavailable
                    }
                    expiresMS = milliseconds
                } else { expiresMS = nil }
                return MobileHostSiteData.Cookie(name: cookie.name, value: cookie.value, domain: cookie.domain,
                    path: cookie.path, expiresMS: expiresMS,
                    secure: cookie.secure, httpOnly: cookie.httpOnly, sameSite: cookie.sameSite)
            }, localStorage: [.init(origin: origin, items: items)])
    }

    private static let storageScript = #"""
    (() => {
      const storage = window.localStorage;
      if (storage.length > 1000) throw new Error('site data too large');
      const items = [];
      let bytes = 0;
      const encoder = new TextEncoder();
      for (let i = 0; i < storage.length; i++) {
        const key = storage.key(i);
        const value = storage.getItem(key);
        if (key === null || value === null) continue;
        bytes += encoder.encode(key).length + encoder.encode(value).length;
        if (bytes > 2097152) throw new Error('site data too large');
        items.push([key, value]);
      }
      return {url: location.href, origin: location.origin, items};
    })()
    """#
}

public enum MobileSiteDataExportError: Error, Equatable {
    case unavailable
    case privateProfile
    case pageChanged
}
