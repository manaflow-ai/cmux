import Foundation

struct BrowserSSLTrustGrant: Hashable {
    let scope: BrowserSSLTrustScope
    let fingerprint: BrowserServerTrustFingerprint
}
