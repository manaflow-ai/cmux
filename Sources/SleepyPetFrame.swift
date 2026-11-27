import SwiftUI

/// One walking pet's per-frame layout, shared between the renderer and the
/// tap hit-testing so both agree on where each pet is.
struct SleepyPetFrame {
    let rect: CGRect
    let color: Color
    let index: Int
    let facingRight: Bool
    let step: Int
    let cell: CGFloat
}
