import AppKit
import CEFKit

let app = CEFKitApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
