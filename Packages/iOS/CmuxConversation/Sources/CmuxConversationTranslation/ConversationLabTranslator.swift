#if DEBUG
import CmuxConversationCore
import Foundation

/// DEBUG lab stand-in for the on-device translator, for hosts where Apple's
/// Translation framework reports every language unsupported (Simulator, EC2
/// Macs). Knows the conversation-sim `intl` corpus; anything else comes back
/// marked so a screenshot never passes a fake off as real output.
/// Selected with `CMUX_CONVERSATION_LAB_TRANSLATOR=canned`.
@MainActor
public final class ConversationLabTranslator: ConversationTranslating {
    public init() {}

    public static var isRequested: Bool {
        ProcessInfo.processInfo.environment["CMUX_CONVERSATION_LAB_TRANSLATOR"] == "canned"
    }

    public func availability(from source: Locale.Language, to target: Locale.Language) async -> ConversationTranslationAvailability {
        .installed
    }

    public func supportedLanguages() async -> [Locale.Language] {
        ["de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh"].map(Locale.Language.init(identifier:))
    }

    public func translate(_ texts: [String: String], from source: Locale.Language, to target: Locale.Language) async throws -> [String: String] {
        texts.mapValues { Self.english[$0] ?? "[\(target.minimalIdentifier)] \($0)" }
    }

    private static let english: [String: String] = [
        "¡Hola! ¿Cómo va todo por allá?": "Hi! How is everything over there?",
        "Acabo de probar la nueva versión y el desplazamiento se siente mucho más fluido.": "I just tried the new version and scrolling feels much smoother.",
        "¿Nos vemos mañana para revisar el diseño?": "Shall we meet tomorrow to review the design?",
        "Perdón por la demora, estuve en una reunión toda la tarde.": "Sorry for the delay, I was in a meeting all afternoon.",
        "Me encanta cómo quedaron las burbujas de los mensajes.": "I love how the message bubbles turned out.",
        "¿Alguien sabe por qué falla la compilación nocturna?": "Does anyone know why the nightly build is failing?",
        "Voy a preparar café, ¿quieren algo?": "I'm going to make coffee, do you want anything?",
        "Gracias por la ayuda de ayer, de verdad me salvaste.": "Thanks for the help yesterday, you really saved me.",
        "El vuelo sale a las ocho, así que llego tarde a la llamada.": "The flight leaves at eight, so I'll be late to the call.",
        "Creo que el problema está en cómo se reconecta el socket después de dormir.": "I think the problem is how the socket reconnects after sleep.",
        "¡Qué buena noticia! Felicidades al equipo.": "What great news! Congratulations to the team.",
        "Mañana hace sol, podríamos trabajar desde el parque.": "It's sunny tomorrow, we could work from the park.",
        "No encuentro el enlace al documento, ¿me lo pasas?": "I can't find the link to the document, can you send it to me?",
        "Ya subí los cambios, avísame si ves algo raro.": "I pushed the changes, let me know if you see anything odd.",
        "おはようございます！今日もよろしくお願いします。": "Good morning! Looking forward to working with you today.",
        "新しいビルドを試してみました。スクロールがとても滑らかです。": "I tried the new build. Scrolling is very smooth.",
        "明日の打ち合わせは何時からですか？": "What time does tomorrow's meeting start?",
        "すみません、少し遅れます。電車が止まっています。": "Sorry, I'll be a little late. The train has stopped.",
        "このバグは再接続のタイミングが原因だと思います。": "I think this bug is caused by the reconnect timing.",
        "ランチに行きませんか？駅前の新しいラーメン屋が気になっています。": "Want to get lunch? I'm curious about the new ramen place by the station.",
        "資料を共有しました。確認してもらえると助かります。": "I shared the document. It would help if you could check it.",
        "週末は京都に行ってきました。紅葉がとてもきれいでした。": "I went to Kyoto over the weekend. The autumn leaves were beautiful.",
        "ありがとうございます！とても助かりました。": "Thank you! That helped a lot.",
        "テストが全部通りました。マージしても大丈夫だと思います。": "All the tests passed. I think it's fine to merge.",
        "今夜のリリースは延期になりそうです。": "Tonight's release will probably be postponed.",
        "その件については後で詳しく説明しますね。": "I'll explain that in detail later.",
        "Salut tout le monde ! Vous avez passé un bon week-end ?": "Hi everyone! Did you have a good weekend?",
        "J'ai testé la dernière version, les animations sont vraiment réussies.": "I tested the latest version, the animations are really well done.",
        "On peut décaler la réunion à quinze heures ?": "Can we move the meeting to 3 p.m.?",
        "Je pense que le problème vient du cache des images.": "I think the problem comes from the image cache.",
        "Merci beaucoup pour ton aide, c'était parfait.": "Thank you so much for your help, it was perfect.",
        "Il pleut encore à Paris, quelle surprise.": "It's raining in Paris again, what a surprise.",
        "Quelqu'un a le lien vers la maquette ?": "Does anyone have the link to the mockup?",
        "Je viens de pousser un correctif, dites-moi si ça marche chez vous.": "I just pushed a fix, tell me if it works for you.",
        "Bon appétit ! Je reviens dans une heure.": "Enjoy your meal! I'll be back in an hour.",
        "La compilation de nuit a encore échoué, je regarde ça.": "The nightly build failed again, I'm looking into it.",
        "C'est une excellente idée, allons-y.": "That's a great idea, let's go.",
        "Je serai en vacances la semaine prochaine.": "I'll be on vacation next week.",
    ]
}
#endif
