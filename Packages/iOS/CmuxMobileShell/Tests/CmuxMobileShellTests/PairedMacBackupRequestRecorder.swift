import Foundation

actor PairedMacBackupRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func reset() {
        requests = []
    }
}
