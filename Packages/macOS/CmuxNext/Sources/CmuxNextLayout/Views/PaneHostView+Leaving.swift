import CmuxNextDesign

/// The pane's content asks its host whether the pane left the layout (``PaneHostView/isLeaving``): a tab bar keeps the
/// tabs of a pane that a close took out, until the frame that hides the host.
extension PaneHostView: PaneLeaving {}
