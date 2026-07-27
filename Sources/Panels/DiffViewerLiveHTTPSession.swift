import Foundation

struct DiffViewerLiveHTTPSession {
    let scheme: String
    let host: String
    let port: Int
    var lastAuthenticatedActivityAt: Date
}
