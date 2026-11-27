import CmuxSwiftRender

/// ``InterpreterClient`` is the out-of-process, crash-isolating
/// ``SidebarInterpreting``: each `render` runs in a supervised worker, so an
/// interpreter fault returns `nil` instead of crashing the host.
extension InterpreterClient: SidebarInterpreting {}
