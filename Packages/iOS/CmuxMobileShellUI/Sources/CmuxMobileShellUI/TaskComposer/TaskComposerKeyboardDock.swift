#if os(iOS)
import SwiftUI
import UIKit

struct TaskComposerKeyboardDock<Canvas: View, Accessory: View>: UIViewControllerRepresentable {
    let canvas: Canvas
    let accessory: Accessory

    func makeUIViewController(
        context: Context
    ) -> TaskComposerKeyboardDockViewController<Canvas, Accessory> {
        TaskComposerKeyboardDockViewController(
            canvas: canvas,
            accessory: accessory
        )
    }

    func updateUIViewController(
        _ viewController: TaskComposerKeyboardDockViewController<Canvas, Accessory>,
        context: Context
    ) {
        viewController.canvas = canvas
        viewController.accessory = accessory
    }
}

@MainActor
final class TaskComposerKeyboardDockViewController<Canvas: View, Accessory: View>: UIViewController {
    var canvas: Canvas {
        get { canvasHostingController.rootView }
        set { canvasHostingController.rootView = newValue }
    }

    var accessory: Accessory {
        get { accessoryHostingController.rootView }
        set { accessoryHostingController.rootView = newValue }
    }

    private let canvasHostingController: UIHostingController<Canvas>
    private let accessoryHostingController: UIHostingController<Accessory>

    init(canvas: Canvas, accessory: Accessory) {
        canvasHostingController = UIHostingController(rootView: canvas)
        accessoryHostingController = UIHostingController(rootView: accessory)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used in storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let keyboardGuide = view.keyboardLayoutGuide
        // A floating iPad keyboard must not pull this full-width dock into the
        // middle of the canvas. Docked keyboards move the guide normally;
        // undocked keyboards leave the controls at the bottom safe area.
        keyboardGuide.followsUndockedKeyboard = false
        keyboardGuide.usesBottomSafeArea = true

        addChild(canvasHostingController)
        canvasHostingController.view.backgroundColor = .clear
        canvasHostingController.safeAreaRegions = []
        canvasHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasHostingController.view)

        addChild(accessoryHostingController)
        accessoryHostingController.view.backgroundColor = .clear
        accessoryHostingController.safeAreaRegions = []
        accessoryHostingController.sizingOptions = [.intrinsicContentSize]
        accessoryHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        accessoryHostingController.view.setContentHuggingPriority(.required, for: .vertical)
        accessoryHostingController.view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(accessoryHostingController.view)

        NSLayoutConstraint.activate([
            canvasHostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            canvasHostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasHostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasHostingController.view.bottomAnchor.constraint(equalTo: accessoryHostingController.view.topAnchor),

            accessoryHostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            accessoryHostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            accessoryHostingController.view.bottomAnchor.constraint(equalTo: keyboardGuide.topAnchor),
        ])

        canvasHostingController.didMove(toParent: self)
        accessoryHostingController.didMove(toParent: self)
    }
}
#endif
