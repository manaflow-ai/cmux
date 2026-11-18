@testable import CmuxNextBrowser
import Foundation
import Testing

/// A corpus of real-looking verification emails, in the shapes and languages sites send
/// (plans/cmux-next/email-verification-autofill/DESIGN.md "Extraction"): each one gives exactly
/// its code. The mails are written for this test; no real mail is checked in.
@Suite struct VerificationEmailCorpusTests {
    let parser = VerificationMessageParser()

    nonisolated struct Sample: Sendable, CustomTestStringConvertible {
        let name: String
        let subject: String
        let body: String
        let code: String
        var testDescription: String { name }
    }

    static func email(_ sample: Sample) -> VerificationEmail {
        VerificationEmail(id: "m-\(sample.name)", senderAddress: "no-reply@example.com", senderAuthenticated: nil,
                          subject: sample.subject, body: sample.body, links: [], receivedAt: Date(timeIntervalSince1970: 1_000))
    }

    nonisolated static let codes: [Sample] = [
        Sample(name: "slack letters and digits 3-3", subject: "Slack confirmation code: Q7K-2PL",
               body: "Confirm your email address\nYour confirmation code is below — enter it in your open browser window and we'll help you get signed in.\nQ7K-2PL\nIf you didn't request this email, there's nothing to worry about.",
               code: "Q7K2PL"),
        Sample(name: "slack letters only 3-3", subject: "Slack confirmation code: KPD-XMF",
               body: "Your confirmation code is below — enter it in your open browser window.\nKPD-XMF",
               code: "KPDXMF"),
        Sample(name: "google G- prefix", subject: "G-482913 is your Google verification code",
               body: "Google\nVerify your email\nG-482913\nUse this code to finish setting up.", code: "482913"),
        Sample(name: "github device verification", subject: "[GitHub] Please verify your device",
               body: "Hey octocat!\nA sign in attempt requires further verification because we did not recognize your device.\nVerification code: 482913\nIf you did not attempt to sign in, change your password.", code: "482913"),
        Sample(name: "microsoft security code 7 digits", subject: "Microsoft account security code",
               body: "Please use the following security code for the Microsoft account le**@cmux.com.\nSecurity code: 4829135\nIf you don't recognize the Microsoft account, you can click here to remove your email.", code: "4829135"),
        Sample(name: "amazon one-time password", subject: "Amazon password assistance",
               body: "To authenticate, please use the following One Time Password (OTP):\n482913\nDon't share this OTP with anyone.", code: "482913"),
        Sample(name: "stripe dashed digits", subject: "Your Stripe verification code",
               body: "Your Stripe verification code is: 482-913\nThis code expires in 10 minutes.", code: "482913"),
        Sample(name: "code on the next line after a blank", subject: "Your login code",
               body: "Here is your login code:\n\n482913\n\nThis code will expire in 15 minutes. Questions? Call 1 800 555 0100.", code: "482913"),
        Sample(name: "code in the subject only", subject: "482913 is your Discord verification code",
               body: "Thanks for using Discord. If you did not request this, ignore this email.", code: "482913"),
        Sample(name: "spaced digits", subject: "Your sign-in code", body: "Your sign-in code is 482 913", code: "482913"),
        Sample(name: "quoted code", subject: "Your one-time code", body: "Enter the code \"482913\" to continue.", code: "482913"),
        Sample(name: "8 character alphanumeric", subject: "Verify your email", body: "Your verification code: X7KQ29PM", code: "X7KQ29PM"),
        Sample(name: "german", subject: "Ihr Bestätigungscode", body: "Ihr Bestätigungscode lautet: 482913\nDer Code ist 10 Minuten gültig.", code: "482913"),
        Sample(name: "spanish", subject: "Tu código de verificación", body: "Tu código de verificación es 482913.", code: "482913"),
        Sample(name: "french", subject: "Votre code de connexion", body: "Voici votre code de connexion : 482913", code: "482913"),
        Sample(name: "portuguese", subject: "Seu código", body: "Seu código de verificação é: 482913", code: "482913"),
        Sample(name: "italian", subject: "Il tuo codice di verifica", body: "Il tuo codice di verifica è 482913", code: "482913"),
        Sample(name: "dutch", subject: "Je verificatiecode", body: "Je verificatiecode is 482913", code: "482913"),
        Sample(name: "polish", subject: "Twój kod", body: "Twój kod weryfikacyjny to 482913", code: "482913"),
        Sample(name: "turkish", subject: "Doğrulama kodunuz", body: "Doğrulama kodunuz: 482913", code: "482913"),
        Sample(name: "russian", subject: "Код подтверждения", body: "Ваш код подтверждения: 482913", code: "482913"),
        Sample(name: "japanese", subject: "認証コードのお知らせ", body: "認証コード：482913\nこのコードの有効期限は10分です。", code: "482913"),
        Sample(name: "chinese simplified", subject: "您的验证码", body: "您的验证码是 482913，10分钟内有效。", code: "482913"),
        Sample(name: "chinese traditional", subject: "您的驗證碼", body: "您的驗證碼為：482913", code: "482913"),
        Sample(name: "korean", subject: "인증 코드", body: "인증 코드: 482913", code: "482913"),
        Sample(name: "vietnamese", subject: "Mã xác minh của bạn", body: "Mã xác minh của bạn là 482913", code: "482913"),
    ]

    @Test(arguments: codes)
    func findsExactlyTheCode(_ sample: Sample) {
        #expect(parser.parse(Self.email(sample)).codes == [sample.code])
    }

    nonisolated static let noCodes: [Sample] = [
        Sample(name: "newsletter with a promo code", subject: "Black Friday: 30% off",
               body: "Use promo code SAVE30 at checkout. Order by 11/28/2026. Call 415 555 0100.", code: ""),
        Sample(name: "receipt", subject: "Your receipt from Example #4829-1355",
               body: "Amount paid $1,299.00\nDate paid Nov 15, 2026\nReceipt number 4829-1355", code: ""),
        Sample(name: "shipping with tracking code", subject: "Your package shipped",
               body: "Tracking code: 1Z999AA10123456784\nZip code 94107", code: ""),
        Sample(name: "meeting invite", subject: "Invitation: Sync @ Mon Nov 16, 2026 10am",
               body: "Join with Google Meet\nmeet.google.com/abc-defg-hij\nJoin by phone +1 650-555-0100 PIN: 482913482#", code: ""),
        Sample(name: "security alert without a code", subject: "Security alert",
               body: "A new sign-in on Mac. If this was you, you don't need to do anything. © 2026 Google LLC", code: ""),
    ]

    @Test(arguments: noCodes)
    func findsNoCode(_ sample: Sample) {
        #expect(parser.parse(Self.email(sample)).codes.isEmpty)
    }
}
