import CmuxTerminalBackend
import CmuxCore
import Foundation

/// Exact identity of one daemon-owned browser placement endpoint.
///
/// Daemon-rendered endpoints fence a presentation to the runtime that emits
/// frames. Frontend-native endpoints use the same identity for canonical
/// placement while WebKit remains owned by the Swift client.
struct TerminalBackendBrowserEndpointIdentity: Equatable, Sendable {
    let authority: BackendAuthority
    let surfaceHandle: UInt64
    let surfaceID: SurfaceID
    let transport: CanonicalBrowserEndpoint.Transport
}

/// A canonical browser endpoint plus non-identity runtime metadata.
struct TerminalBackendBrowserEndpoint: Equatable, Sendable {
    let identity: TerminalBackendBrowserEndpointIdentity
    let source: CanonicalBrowserEndpoint.Source?

    init(authority: BackendAuthority, surface: CanonicalSurface) throws {
        guard surface.kind.lowercased() == "browser" else {
            throw TerminalBackendBrowserEndpointError.notBrowser(
                surfaceID: surface.uuid.rawValue,
                kind: surface.kind
            )
        }
        guard let descriptor = surface.browserEndpoint else {
            throw TerminalBackendBrowserEndpointError.missingDescriptor(
                surfaceID: surface.uuid.rawValue
            )
        }
        identity = TerminalBackendBrowserEndpointIdentity(
            authority: authority,
            surfaceHandle: surface.id,
            surfaceID: surface.uuid,
            transport: descriptor.transport
        )
        source = descriptor.source
    }
}

/// Whether a browser panel is a Swift-owned WKWebView or a projection of one
/// exact daemon browser runtime.
enum BrowserPanelEndpointProvenance: Equatable, Sendable {
    case clientOverlay
    case frontendNativeCanonical(SurfaceID)
    case backend(TerminalBackendBrowserEndpointIdentity)

    var canonicalSurfaceID: SurfaceID? {
        switch self {
        case .clientOverlay:
            nil
        case .frontendNativeCanonical(let surfaceID):
            surfaceID
        case .backend(let endpoint):
            endpoint.surfaceID
        }
    }
}

enum TerminalBackendBrowserEndpointError: Error, Equatable, Sendable {
    case notBrowser(surfaceID: UUID, kind: String)
    case missingDescriptor(surfaceID: UUID)
    case clientOverlayCollision(surfaceID: UUID)
    case stalePresentation(
        surfaceID: UUID,
        expected: TerminalBackendBrowserEndpointIdentity,
        actual: TerminalBackendBrowserEndpointIdentity
    )
    case unsupportedContentTransport(TerminalBackendBrowserEndpointIdentity)
    case invalidFactoryResult(surfaceID: UUID)
}

extension TerminalBackendBrowserEndpointError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notBrowser(let surfaceID, let kind):
            "surface \(surfaceID.uuidString) has non-browser kind \(kind)"
        case .missingDescriptor(let surfaceID):
            "canonical browser \(surfaceID.uuidString) has no content endpoint descriptor"
        case .clientOverlayCollision(let surfaceID):
            "client-owned browser \(surfaceID.uuidString) collides with a canonical browser identity"
        case .stalePresentation(let surfaceID, _, _):
            "browser presentation \(surfaceID.uuidString) belongs to a different daemon runtime"
        case .unsupportedContentTransport(let identity):
            "browser content transport \(identity.transport.rawValue) is not implemented for \(identity.surfaceID)"
        case .invalidFactoryResult(let surfaceID):
            "browser endpoint factory returned an unverified presentation for \(surfaceID.uuidString)"
        }
    }
}

/// Factory for a presentation of one exact canonical browser endpoint.
///
/// Frontend-native endpoints create a local WKWebView keyed by the canonical
/// surface UUID. Daemon-rendered endpoints may only be created by a factory
/// that consumes their advertised frame and input streams.
@MainActor
protocol TerminalBackendBrowserEndpointCreating {
    func validate(_ endpoint: TerminalBackendBrowserEndpoint) throws
    func makeBrowserPanel(
        endpoint: TerminalBackendBrowserEndpoint,
        workspaceID: UUID
    ) throws -> BrowserPanel
}

struct TerminalBackendNativeBrowserPresentationRequest: Sendable {
    let url: URL?
    let initialRequest: URLRequest?
    let profileID: UUID?
    let preloadInitialNavigationInBackground: Bool
    let bypassInsecureHTTPHostOnce: String?
    let omnibarVisible: Bool
    let transparentBackground: Bool
    let proxyEndpoint: BrowserProxyEndpoint?
    let bypassRemoteProxy: Bool
    let isRemoteWorkspace: Bool
    let remoteWebsiteDataStoreIdentifier: UUID?

    init(
        url: URL?,
        initialRequest: URLRequest? = nil,
        profileID: UUID?,
        preloadInitialNavigationInBackground: Bool = false,
        bypassInsecureHTTPHostOnce: String? = nil,
        omnibarVisible: Bool,
        transparentBackground: Bool,
        proxyEndpoint: BrowserProxyEndpoint? = nil,
        bypassRemoteProxy: Bool = false,
        isRemoteWorkspace: Bool = false,
        remoteWebsiteDataStoreIdentifier: UUID? = nil
    ) {
        self.url = url
        self.initialRequest = initialRequest
        self.profileID = profileID
        self.preloadInitialNavigationInBackground = preloadInitialNavigationInBackground
        self.bypassInsecureHTTPHostOnce = bypassInsecureHTTPHostOnce
        self.omnibarVisible = omnibarVisible
        self.transparentBackground = transparentBackground
        self.proxyEndpoint = proxyEndpoint
        self.bypassRemoteProxy = bypassRemoteProxy
        self.isRemoteWorkspace = isRemoteWorkspace
        self.remoteWebsiteDataStoreIdentifier = remoteWebsiteDataStoreIdentifier
    }
}

@MainActor
final class TerminalBackendNativeBrowserPresentationRegistry {
    private let maximumPendingRequestCount: Int
    private var pendingRequests: [SurfaceID: TerminalBackendNativeBrowserPresentationRequest] = [:]
    private var pendingRequestOrder: [SurfaceID] = []

    init(maximumPendingRequestCount: Int = 256) {
        precondition(maximumPendingRequestCount > 0)
        self.maximumPendingRequestCount = maximumPendingRequestCount
    }

    /// Registers private frontend runtime state without serializing it into the
    /// canonical topology. New registrations fail closed once the bounded
    /// pending set is full so credential-bearing requests are never evicted
    /// while their matching daemon mutation may still project.
    @discardableResult
    func register(
        _ request: TerminalBackendNativeBrowserPresentationRequest,
        for surfaceID: SurfaceID
    ) -> Bool {
        if pendingRequests[surfaceID] != nil {
            pendingRequests[surfaceID] = request
            return true
        }
        guard pendingRequests.count < maximumPendingRequestCount else {
            return false
        }
        pendingRequests[surfaceID] = request
        pendingRequestOrder.append(surfaceID)
        return true
    }

    func request(for surfaceID: SurfaceID) -> TerminalBackendNativeBrowserPresentationRequest? {
        pendingRequests[surfaceID]
    }

    func remove(_ surfaceID: SurfaceID) {
        guard pendingRequests.removeValue(forKey: surfaceID) != nil else {
            return
        }
        pendingRequestOrder.removeAll { $0 == surfaceID }
    }

    func removeAll() {
        pendingRequests.removeAll(keepingCapacity: false)
        pendingRequestOrder.removeAll(keepingCapacity: false)
    }

    var pendingRequestCount: Int {
        pendingRequests.count
    }
}

/// Production behavior for canonical native WebKit placement. PNG endpoints
/// remain unsupported and are omitted when marked frontend-optional.
@MainActor
struct NativeTerminalBackendBrowserEndpointFactory:
    TerminalBackendBrowserEndpointCreating
{
    let presentationRegistry: TerminalBackendNativeBrowserPresentationRegistry
    var claimedSourceURL: @MainActor (SurfaceID) -> URL? = { _ in nil }

    func validate(_ endpoint: TerminalBackendBrowserEndpoint) throws {
        guard endpoint.identity.transport == .frontendNativeV1 else {
            throw TerminalBackendBrowserEndpointError.unsupportedContentTransport(
                endpoint.identity
            )
        }
    }

    func makeBrowserPanel(
        endpoint: TerminalBackendBrowserEndpoint,
        workspaceID: UUID
    ) throws -> BrowserPanel {
        try validate(endpoint)
        let request = presentationRegistry.request(
            for: endpoint.identity.surfaceID
        )
        return BrowserPanel(
            id: endpoint.identity.surfaceID.rawValue,
            workspaceId: workspaceID,
            endpointProvenance: .frontendNativeCanonical(
                endpoint.identity.surfaceID
            ),
            profileID: request?.profileID,
            initialURL: request?.url
                ?? request?.initialRequest?.url
                ?? claimedSourceURL(endpoint.identity.surfaceID),
            initialRequest: request?.initialRequest,
            preloadInitialNavigationInBackground:
                request?.preloadInitialNavigationInBackground ?? false,
            bypassInsecureHTTPHostOnce: request?.bypassInsecureHTTPHostOnce,
            omnibarVisible: request?.omnibarVisible ?? true,
            transparentBackground: request?.transparentBackground ?? false,
            proxyEndpoint: request?.proxyEndpoint,
            bypassRemoteProxy: request?.bypassRemoteProxy ?? false,
            isRemoteWorkspace: request?.isRemoteWorkspace ?? false,
            remoteWebsiteDataStoreIdentifier: request?.remoteWebsiteDataStoreIdentifier
        )
    }
}

@MainActor
struct UnsupportedTerminalBackendBrowserEndpointFactory:
    TerminalBackendBrowserEndpointCreating
{
    func validate(_ endpoint: TerminalBackendBrowserEndpoint) throws {
        throw TerminalBackendBrowserEndpointError.unsupportedContentTransport(
            endpoint.identity
        )
    }

    func makeBrowserPanel(
        endpoint: TerminalBackendBrowserEndpoint,
        workspaceID _: UUID
    ) throws -> BrowserPanel {
        throw TerminalBackendBrowserEndpointError.unsupportedContentTransport(
            endpoint.identity
        )
    }
}

@MainActor
struct TerminalBackendBrowserEndpointResolver {
    let factory: any TerminalBackendBrowserEndpointCreating

    func endpoint(
        authority: BackendAuthority,
        surface: CanonicalSurface
    ) throws -> TerminalBackendBrowserEndpoint {
        try TerminalBackendBrowserEndpoint(authority: authority, surface: surface)
    }

    func validateExisting(
        _ panel: BrowserPanel,
        endpoint: TerminalBackendBrowserEndpoint
    ) throws {
        if endpoint.identity.transport == .frontendNativeV1 {
            guard panel.endpointProvenance == .frontendNativeCanonical(
                endpoint.identity.surfaceID
            ) else {
                throw TerminalBackendBrowserEndpointError.clientOverlayCollision(
                    surfaceID: endpoint.identity.surfaceID.rawValue
                )
            }
            return
        }
        switch panel.endpointProvenance {
        case .clientOverlay:
            throw TerminalBackendBrowserEndpointError.clientOverlayCollision(
                surfaceID: endpoint.identity.surfaceID.rawValue
            )
        case .frontendNativeCanonical:
            throw TerminalBackendBrowserEndpointError.unsupportedContentTransport(
                endpoint.identity
            )
        case .backend(let actual):
            guard actual == endpoint.identity else {
                throw TerminalBackendBrowserEndpointError.stalePresentation(
                    surfaceID: endpoint.identity.surfaceID.rawValue,
                    expected: endpoint.identity,
                    actual: actual
                )
            }
        }
    }

    func validateMaterialization(_ endpoint: TerminalBackendBrowserEndpoint) throws {
        try factory.validate(endpoint)
    }

    func materialize(
        _ endpoint: TerminalBackendBrowserEndpoint,
        workspaceID: UUID
    ) throws -> BrowserPanel {
        let panel = try factory.makeBrowserPanel(
            endpoint: endpoint,
            workspaceID: workspaceID
        )
        let expectedProvenance: BrowserPanelEndpointProvenance =
            endpoint.identity.transport == .frontendNativeV1
            ? .frontendNativeCanonical(endpoint.identity.surfaceID)
            : .backend(endpoint.identity)
        guard panel.id == endpoint.identity.surfaceID.rawValue,
              panel.workspaceId == workspaceID,
              panel.endpointProvenance == expectedProvenance else {
            panel.close()
            throw TerminalBackendBrowserEndpointError.invalidFactoryResult(
                surfaceID: endpoint.identity.surfaceID.rawValue
            )
        }
        return panel
    }
}
