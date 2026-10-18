import Foundation

/// Public docs pages that Cloud onboarding, empty states and recovery
/// actions link to. Every path is a real route under `web/app/[locale]/(landing)/docs/`.
enum CloudDocsLinks {
    /// What Cloud is and how to start.
    static let overview = URL(string: "https://cmux.com/docs/cloud")!
    /// Creating, sizing, sleeping and waking machines.
    static let machines = URL(string: "https://cmux.com/docs/cloud/machines")!
    /// Cloud Secrets: API keys every machine receives.
    static let secrets = URL(string: "https://cmux.com/docs/cloud/secrets")!
    /// `cmux vm clone`: open a repo on a machine and start an agent.
    static let openRepo = URL(string: "https://cmux.com/docs/cloud/open-repo")!
    /// What to check when a machine, the list or setup will not load.
    static let troubleshooting = URL(string: "https://cmux.com/docs/cloud/troubleshooting")!
}
