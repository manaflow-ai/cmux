import UIKit

// AutoFill pill probe: one UITextView with the composer's traits, varied by
// the launch argument `-variant N`; it focuses itself so the soft keyboard shows.
final class NoAutoFillTextView: UITextView {
    override func buildMenu(with builder: any UIMenuBuilder) {
        builder.remove(menu: .autoFill)
        super.buildMenu(with: builder)
    }
}

final class VC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        let args0 = ProcessInfo.processInfo.arguments
        let tv: UITextView = args0.contains("-fix") ? NoAutoFillTextView() : UITextView()
        tv.font = .preferredFont(forTextStyle: .body)
        tv.backgroundColor = .darkGray
        tv.keyboardAppearance = .dark
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.spellCheckingType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.inlinePredictionType = .no
        tv.textContentType = nil
        tv.writingToolsBehavior = .none
        tv.returnKeyType = .send
        let args = ProcessInfo.processInfo.arguments
        let v = args.firstIndex(of: "-variant").flatMap { Int(args[$0 + 1]) } ?? 0
        let label = UILabel()
        label.textColor = .white
        switch v {
        case 1: tv.textContentType = .URL; label.text = "1 URL"
        case 2: tv.textContentType = .flightNumber; label.text = "2 flightNumber"
        case 3: tv.keyboardType = .asciiCapable; label.text = "3 asciiCapable"
        case 4: tv.textContentType = UITextContentType(rawValue: ""); label.text = "4 empty raw"
        case 5: tv.textContentType = .dateTime; label.text = "5 dateTime"
        case 6: tv.keyboardType = .URL; label.text = "6 kb URL"
        case 7: tv.textContentType = .oneTimeCode; label.text = "7 oneTimeCode"
        case 8: tv.textContentType = .shipmentTrackingNumber; label.text = "8 shipment"
        case 9: tv.keyboardType = .asciiCapable; tv.textContentType = .URL; label.text = "9 ascii+URL"
        case 10: tv.textContentType = UITextContentType(rawValue: "none"); label.text = "10 raw none"
        default: label.text = "0 current"
        }
        tv.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tv); view.addSubview(label)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tv.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tv.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            tv.heightAnchor.constraint(equalToConstant: 44),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tv.becomeFirstResponder() }
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = VC()
        window?.makeKeyAndVisible()
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
