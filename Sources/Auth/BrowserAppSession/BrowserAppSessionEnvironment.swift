import Foundation

/// Identifies the web environment whose cookies belong to an app session.
struct BrowserAppSessionEnvironment: Hashable {
    let webOrigin: URL
    let projectID: String

    init(webOrigin: URL, projectID: String) {
        self.webOrigin = webOrigin
        self.projectID = projectID
    }
}
