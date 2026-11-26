#if canImport(CmuxMobileLinkFFI)
import CmuxEgress
import CmuxMobileLinkFFI
import Foundation
import Network

/// Looks for Macs nearby (ultra-connectivity P7): browses Bonjour `_cmux-link._tcp` over Wi-Fi and
/// peer-to-peer (AWDL), so a Mac with no internet beside the phone is found with no cloud round
/// trip. A thin shim: it hands each result's TXT pairs and resolved addresses to the Rust core
/// (`localLinkObserve`), which decides whether the ad is the paired Mac and whether a dial goes
/// through its hub first (`cmux-mobile-link-ffi` `local_link.rs`). No policy here.
public final class LocalLinkBrowser: @unchecked Sendable {
    public static let shared = LocalLinkBrowser()

    /// The type the Mac advertises (`cmux_mobile_link::local::BONJOUR_TYPE`).
    static let serviceType = "_cmux-link._tcp"

    private let queue = DispatchQueue(label: "dev.cmux.mobile.local-link")
    // Confined to `queue`.
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]
    /// Between start() and stop(): a failed browse restarts only while browsing is wanted.
    private var wanted = false

    private init() {}

    /// Start browsing; a second call while browsing does nothing.
    public func start() {
        queue.async {
            self.wanted = true
            self.startOnQueue()
        }
    }

    public func stop() {
        queue.async {
            self.wanted = false
            self.browser?.cancel()
            self.browser = nil
            for connection in self.resolving.values { connection.cancel() }
            self.resolving.removeAll()
        }
    }

    private func startOnQueue() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        // AWDL: a Mac beside the phone with no shared network is still found.
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self else { return }
            for change in changes {
                switch change {
                case .added(let result), .changed(old: _, new: let result, flags: _):
                    self.resolve(result)
                case .removed(let result):
                    if let name = Self.instanceName(result.endpoint) { localLinkRemove(instance: name) }
                default:
                    break
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting:
                // No permission or no network yet (a declined Local Network prompt lands here): the
                // browser resumes by itself when that changes; the half-made resolves are dropped.
                self?.queue.async {
                    guard let self else { return }
                    for connection in self.resolving.values { connection.cancel() }
                    self.resolving.removeAll()
                }
            case .failed:
                // A failed browse (the radio reset, mDNS restarted) starts again by itself after a
                // pause, not only at the next dial's start(): the Mac stays findable meanwhile.
                self?.queue.async {
                    self?.browser = nil
                    self?.queue.asyncAfter(deadline: .now() + .seconds(5)) {
                        if self?.wanted == true { self?.startOnQueue() }
                    }
                }
            case .cancelled:
                // stop(), or a failed browse being replaced; the next start() browses again.
                break
            default:
                break
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private static func instanceName(_ endpoint: NWEndpoint) -> String? {
        if case .service(let name, _, _, _) = endpoint { return name }
        return nil
    }

    /// One connection to the service finds its address (the platform resolves it, over the
    /// interface it was found on); the connection is dropped once its path is known.
    private func resolve(_ result: NWBrowser.Result) {
        guard let name = Self.instanceName(result.endpoint) else { return }
        var pairs: [LocalTxt] = []
        if case .bonjour(let record) = result.metadata {
            pairs = record.dictionary.map { LocalTxt(key: $0.key, value: $0.value) }
        }
        // The core says whether this ad is worth a connection: a paired Mac's, with its key's tag,
        // not already live (a TXT refresh of the same ad resolves nothing).
        guard localLinkWantsResolve(instance: name, txt: pairs) else { return }
        resolving[name]?.cancel()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = CmuxEgress.connection(to: result.endpoint, using: parameters, site: "CmuxMobileTransport.LocalLinkBrowser")
        resolving[name] = connection
        let txt = pairs
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                    let endpoint = LocalEndpoint(host: "\(host)", port: port.rawValue)
                    _ = localLinkObserve(instance: name, txt: txt, endpoints: [endpoint])
                }
                connection.cancel()
            case .failed, .cancelled:
                self?.queue.async { if self?.resolving[name] === connection { self?.resolving[name] = nil } }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}
#endif
