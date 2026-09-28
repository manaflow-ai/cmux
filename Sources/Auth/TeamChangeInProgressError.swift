/// A team switch or create was refused because another team change is still
/// in flight. A later coordinator mutation fails an earlier create even though
/// the server made the team, so ``HostAccountFlow`` runs a create alone.
struct TeamChangeInProgressError: Error, Equatable, Sendable {}
