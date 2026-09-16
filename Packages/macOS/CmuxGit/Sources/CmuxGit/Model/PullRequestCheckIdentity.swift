/// Provider/workflow/event scope prevents similarly named jobs from replacing each other.
struct PullRequestCheckIdentity: Hashable, Sendable {
    let kind: String
    let name: String
    let application: String
    let workflow: String
    let event: String
}
