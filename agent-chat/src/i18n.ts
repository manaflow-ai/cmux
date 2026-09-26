export const AGENT_CHAT_LOCALES = [
  "en",
  "ja",
  "zh-CN",
  "zh-TW",
  "ko",
  "de",
  "es",
  "fr",
  "it",
  "da",
  "pl",
  "ru",
  "bs",
  "ar",
  "no",
  "pt-BR",
  "th",
  "tr",
  "km",
  "uk",
] as const;

export type AgentChatLocale = (typeof AGENT_CHAT_LOCALES)[number];
export type AgentChatTextKey =
  | "continuedNewChat"
  | "movedServingRoute"
  | "continueNewChat"
  | "continueElsewhere";

const COPY: Record<AgentChatLocale, Record<AgentChatTextKey, string>> = {
  en: {
    continuedNewChat: "Continued in a new chat. Previous context is linked.",
    movedServingRoute: "Moved to another serving route. Conversation context was preserved.",
    continueNewChat: "Continue in new chat",
    continueElsewhere: "Continue elsewhere",
  },
  ja: {
    continuedNewChat: "新しいチャットで続行しました。以前のコンテキストはリンクされています。",
    movedServingRoute: "別の配信ルートに移動しました。会話のコンテキストは保持されています。",
    continueNewChat: "新しいチャットで続行",
    continueElsewhere: "別の場所で続行",
  },
  "zh-CN": {
    continuedNewChat: "已在新聊天中继续。之前的上下文已关联。",
    movedServingRoute: "已切换到其他服务路由。对话上下文已保留。",
    continueNewChat: "在新聊天中继续",
    continueElsewhere: "在其他位置继续",
  },
  "zh-TW": {
    continuedNewChat: "已在新聊天中繼續。先前的內容已連結。",
    movedServingRoute: "已切換至其他服務路由。對話內容已保留。",
    continueNewChat: "在新聊天中繼續",
    continueElsewhere: "在其他位置繼續",
  },
  ko: {
    continuedNewChat: "새 채팅에서 계속합니다. 이전 컨텍스트가 연결되어 있습니다.",
    movedServingRoute: "다른 서비스 경로로 이동했습니다. 대화 컨텍스트는 유지되었습니다.",
    continueNewChat: "새 채팅에서 계속",
    continueElsewhere: "다른 곳에서 계속",
  },
  de: {
    continuedNewChat: "In einem neuen Chat fortgesetzt. Der vorherige Kontext ist verknüpft.",
    movedServingRoute: "Auf eine andere Bereitstellungsroute gewechselt. Der Gesprächskontext wurde beibehalten.",
    continueNewChat: "In neuem Chat fortfahren",
    continueElsewhere: "Anderswo fortfahren",
  },
  es: {
    continuedNewChat: "Se continuó en un chat nuevo. El contexto anterior está vinculado.",
    movedServingRoute: "Se cambió a otra ruta de servicio. Se conservó el contexto de la conversación.",
    continueNewChat: "Continuar en un chat nuevo",
    continueElsewhere: "Continuar en otro lugar",
  },
  fr: {
    continuedNewChat: "La conversation continue dans un nouveau chat. Le contexte précédent est lié.",
    movedServingRoute: "Passage à une autre route de service. Le contexte de la conversation a été conservé.",
    continueNewChat: "Continuer dans un nouveau chat",
    continueElsewhere: "Continuer ailleurs",
  },
  it: {
    continuedNewChat: "Continuazione in una nuova chat. Il contesto precedente è collegato.",
    movedServingRoute: "Passaggio a un altro percorso di servizio. Il contesto della conversazione è stato mantenuto.",
    continueNewChat: "Continua in una nuova chat",
    continueElsewhere: "Continua altrove",
  },
  da: {
    continuedNewChat: "Fortsat i en ny chat. Den tidligere kontekst er knyttet til.",
    movedServingRoute: "Flyttet til en anden serveringsrute. Samtalens kontekst blev bevaret.",
    continueNewChat: "Fortsæt i ny chat",
    continueElsewhere: "Fortsæt et andet sted",
  },
  pl: {
    continuedNewChat: "Kontynuowano w nowym czacie. Poprzedni kontekst jest połączony.",
    movedServingRoute: "Przeniesiono na inną trasę obsługi. Kontekst rozmowy został zachowany.",
    continueNewChat: "Kontynuuj w nowym czacie",
    continueElsewhere: "Kontynuuj gdzie indziej",
  },
  ru: {
    continuedNewChat: "Продолжено в новом чате. Предыдущий контекст связан.",
    movedServingRoute: "Переключено на другой маршрут обслуживания. Контекст разговора сохранён.",
    continueNewChat: "Продолжить в новом чате",
    continueElsewhere: "Продолжить в другом месте",
  },
  bs: {
    continuedNewChat: "Nastavljeno u novom chatu. Prethodni kontekst je povezan.",
    movedServingRoute: "Prebačeno na drugu servisnu rutu. Kontekst razgovora je sačuvan.",
    continueNewChat: "Nastavi u novom chatu",
    continueElsewhere: "Nastavi drugdje",
  },
  ar: {
    continuedNewChat: "تمت المتابعة في محادثة جديدة. السياق السابق مرتبط.",
    movedServingRoute: "تم الانتقال إلى مسار خدمة آخر. تم الاحتفاظ بسياق المحادثة.",
    continueNewChat: "المتابعة في محادثة جديدة",
    continueElsewhere: "المتابعة في مكان آخر",
  },
  no: {
    continuedNewChat: "Fortsatt i en ny chat. Tidligere kontekst er koblet til.",
    movedServingRoute: "Flyttet til en annen serveringsrute. Samtalekonteksten ble bevart.",
    continueNewChat: "Fortsett i ny chat",
    continueElsewhere: "Fortsett et annet sted",
  },
  "pt-BR": {
    continuedNewChat: "Continuado em um novo chat. O contexto anterior está vinculado.",
    movedServingRoute: "Movido para outra rota de atendimento. O contexto da conversa foi preservado.",
    continueNewChat: "Continuar em um novo chat",
    continueElsewhere: "Continuar em outro lugar",
  },
  th: {
    continuedNewChat: "ดำเนินการต่อในแชทใหม่แล้ว โดยเชื่อมโยงบริบทก่อนหน้าไว้",
    movedServingRoute: "ย้ายไปยังเส้นทางการให้บริการอื่นแล้ว โดยยังคงบริบทการสนทนาไว้",
    continueNewChat: "ดำเนินการต่อในแชทใหม่",
    continueElsewhere: "ดำเนินการต่อที่อื่น",
  },
  tr: {
    continuedNewChat: "Yeni bir sohbette devam edildi. Önceki bağlam bağlantılı.",
    movedServingRoute: "Başka bir hizmet rotasına geçildi. Konuşma bağlamı korundu.",
    continueNewChat: "Yeni sohbette devam et",
    continueElsewhere: "Başka yerde devam et",
  },
  km: {
    continuedNewChat: "បានបន្តនៅក្នុងការជជែកថ្មី។ បរិបទមុនត្រូវបានភ្ជាប់។",
    movedServingRoute: "បានប្តូរទៅផ្លូវបម្រើផ្សេង។ បរិបទនៃការសន្ទនាត្រូវបានរក្សាទុក។",
    continueNewChat: "បន្តក្នុងការជជែកថ្មី",
    continueElsewhere: "បន្តនៅកន្លែងផ្សេង",
  },
  uk: {
    continuedNewChat: "Продовжено в новому чаті. Попередній контекст пов’язано.",
    movedServingRoute: "Перемкнено на інший маршрут обслуговування. Контекст розмови збережено.",
    continueNewChat: "Продовжити в новому чаті",
    continueElsewhere: "Продовжити в іншому місці",
  },
};

const BY_LOWERCASE = new Map(
  AGENT_CHAT_LOCALES.map((locale) => [locale.toLowerCase(), locale] as const),
);

export function resolveAgentChatLocale(languages: readonly string[]): AgentChatLocale {
  for (const raw of languages) {
    const candidate = raw.trim();
    if (!candidate) continue;
    const exact = BY_LOWERCASE.get(candidate.toLowerCase());
    if (exact) return exact;

    const lower = candidate.toLowerCase();
    if (lower.startsWith("zh-")) {
      return /(?:^|-)hant(?:-|$)|-(?:tw|hk|mo)(?:-|$)/.test(lower) ? "zh-TW" : "zh-CN";
    }
    if (lower === "zh") return "zh-CN";
    if (lower === "pt" || lower.startsWith("pt-")) return "pt-BR";
    if (lower === "nb" || lower.startsWith("nb-") || lower === "nn" || lower.startsWith("nn-")) return "no";

    const language = lower.split("-", 1)[0];
    const languageMatch = AGENT_CHAT_LOCALES.find((locale) => locale.toLowerCase().split("-", 1)[0] === language);
    if (languageMatch) return languageMatch;
  }
  return "en";
}

function browserLanguages(): readonly string[] {
  if (typeof navigator === "undefined") return ["en"];
  return navigator.languages.length ? navigator.languages : [navigator.language];
}

export function agentChatText(key: AgentChatTextKey, languages = browserLanguages()): string {
  return COPY[resolveAgentChatLocale(languages)][key];
}

export function agentChatCopyForLocale(locale: AgentChatLocale): Readonly<Record<AgentChatTextKey, string>> {
  return COPY[locale];
}
