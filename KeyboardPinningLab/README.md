# Keyboard Pinning Lab

This standalone iOS app isolates the Workspace Detail keyboard geometry from cmux state and networking.

The Composer and Shortcut bars live in one `ComposerDockView`. Its bottom edge is constrained directly to `UIKeyboardLayoutGuide.topAnchor`. UIKit therefore owns the keyboard frame, the dock frame, and interrupted animation timing in one constraint graph.

The circular-arrow header button reverses first-responder state every 135 ms to stress interrupted keyboard transitions. The header reports the live constraint gap. Green `PIN GAP 0.0 pt` means the dock and keyboard guide are coincident in the current layout pass.

Tapping the terminal canvas focuses the same Composer text field, so terminal tap, direct Composer tap, the keyboard button, and the stress control all exercise one keyboard ownership path.

Generate the Xcode project with `xcodegen generate`, then build the `KeyboardPinningLab` scheme.
