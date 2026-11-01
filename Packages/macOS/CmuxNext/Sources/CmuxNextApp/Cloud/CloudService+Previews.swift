import CmuxNextCloud

extension CloudService {
    /// Same person and team as the machine API, at the platform's preview ingress origin.
    var previewAPI: CloudAPIClient? {
        guard let origin = configuration.platformPreviewAPIBaseURL() else { return nil }
        return machineAPI.previewClient(baseURL: origin)
    }
}
