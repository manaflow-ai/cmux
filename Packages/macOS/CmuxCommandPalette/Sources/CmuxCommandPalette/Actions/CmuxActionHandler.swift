/// Main-actor executor shared by command-palette and automation adapters.
public typealias CmuxActionHandler = @MainActor (CmuxActionInvocation) -> CmuxActionExecutionResult
