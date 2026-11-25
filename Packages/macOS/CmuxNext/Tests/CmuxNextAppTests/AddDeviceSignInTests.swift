@testable import CmuxNextServer
import Testing

/// Lawrence, msg 3790: "everywhere we say sign in, we need to have a button for signing in". Add
/// Device's one-line join, refused because nobody is signed in ("Sign in to cmux to make a line."),
/// offers Sign In as its Return button; it runs the app's Sign In and closes the card. Another
/// failure still offers New Line.
@MainActor @Suite(.serialized) struct AddDeviceSignInTests {
    @Test func aSignedOutLineOffersSignIn() async {
        let fake = MachineJoinLineFlowTests.Fake()
        fake.mintResult = .failure(.signedOut)
        let devices = AddDeviceFlowTests.Fake()
        var signIns = 0
        var services = MachineJoinLineFlowTests.services(devices, fake)
        services.signIn = { signIns += 1 }
        let model = fake.deviceModel(services)
        await model.begin(way: .joinLine)
        await model.joinLine?.mint()
        #expect(model.joinLine?.phase == .failed(.signedOut))
        #expect(model.buttons == [AddDeviceButton(action: .cancel, key: .escape), AddDeviceButton(action: .signIn, key: .return)])
        #expect(model.perform(.signIn), "the card closes while the sign-in runs")
        #expect(signIns == 1)
    }

    @Test func anotherFailureStillOffersNewLine() async {
        let fake = MachineJoinLineFlowTests.Fake()
        fake.mintResult = .failure(.failed)
        let devices = AddDeviceFlowTests.Fake()
        let model = fake.deviceModel(MachineJoinLineFlowTests.services(devices, fake))
        await model.begin(way: .joinLine)
        await model.joinLine?.mint()
        #expect(model.buttons.map(\.action) == [.cancel, .newJoinLine])
    }
}
