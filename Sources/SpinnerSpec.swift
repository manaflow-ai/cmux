#if DEBUG
import Foundation
import SwiftUI

struct SpinnerSpec: Identifiable {
    let id = UUID()
    let title: String
    let mechanism: String
    let energy: SpinnerEnergy
    let shipping: Bool
    let makeView: () -> AnyView
}
#endif
