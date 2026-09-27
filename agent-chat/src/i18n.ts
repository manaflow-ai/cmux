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
  | "continueElsewhere"
  | "transcriptViewRunning"
  | "transcriptViewIdle";

const COPY: Record<AgentChatLocale, Record<AgentChatTextKey, string>> = {
  en: {
    continuedNewChat: "Continued in a new chat. Previous context is linked.",
    movedServingRoute: "Moved to another serving route. Conversation context was preserved.",
    continueNewChat: "Continue in new chat",
    continueElsewhere: "Continue elsewhere",
    transcriptViewRunning: "Agent is working in the terminal. Switch to the terminal to reply or approve.",
    transcriptViewIdle: "Mirroring the terminal session. Switch to the terminal to reply, approve, or run commands.",
  },
  ja: {
    continuedNewChat: "新しいチャットで続行しました。以前のコンテキストはリンクされています。",
    movedServingRoute: "別の配信ルートに移動しました。会話のコンテキストは保持されています。",
    continueNewChat: "新しいチャットで続行",
    continueElsewhere: "別の場所で続行",
    transcriptViewRunning: "エージェントがターミナルで作業中です。返信や承認はターミナルで行ってください。",
    transcriptViewIdle: "ターミナルのセッションを表示しています。返信、承認、コマンド実行はターミナルで行ってください。",
  },
  "zh-CN": {
    continuedNewChat: "已在新聊天中继续。之前的上下文已关联。",
    movedServingRoute: "已切换到其他服务路由。对话上下文已保留。",
    continueNewChat: "在新聊天中继续",
    continueElsewhere: "在其他位置继续",
    transcriptViewRunning: "代理正在终端中工作。请切换到终端进行回复或批准。",
    transcriptViewIdle: "正在镜像终端会话。请切换到终端进行回复、批准或运行命令。",
  },
  "zh-TW": {
    continuedNewChat: "已在新聊天中繼續。先前的內容已連結。",
    movedServingRoute: "已切換至其他服務路由。對話內容已保留。",
    continueNewChat: "在新聊天中繼續",
    continueElsewhere: "在其他位置繼續",
    transcriptViewRunning: "代理程式正在終端機中工作。請切換到終端機回覆或核准。",
    transcriptViewIdle: "正在鏡像終端機工作階段。請切換到終端機回覆、核准或執行指令。",
  },
  ko: {
    continuedNewChat: "새 채팅에서 계속합니다. 이전 컨텍스트가 연결되어 있습니다.",
    movedServingRoute: "다른 서비스 경로로 이동했습니다. 대화 컨텍스트는 유지되었습니다.",
    continueNewChat: "새 채팅에서 계속",
    continueElsewhere: "다른 곳에서 계속",
    transcriptViewRunning: "에이전트가 터미널에서 작업 중입니다. 답장하거나 승인하려면 터미널로 전환하세요.",
    transcriptViewIdle: "터미널 세션을 미러링하고 있습니다. 답장, 승인, 명령 실행은 터미널에서 하세요.",
  },
  de: {
    continuedNewChat: "In einem neuen Chat fortgesetzt. Der vorherige Kontext ist verknüpft.",
    movedServingRoute: "Auf eine andere Bereitstellungsroute gewechselt. Der Gesprächskontext wurde beibehalten.",
    continueNewChat: "In neuem Chat fortfahren",
    continueElsewhere: "Anderswo fortfahren",
    transcriptViewRunning: "Der Agent arbeitet im Terminal. Zum Antworten oder Freigeben ins Terminal wechseln.",
    transcriptViewIdle: "Spiegelt die Terminalsitzung. Zum Antworten, Freigeben oder für Befehle ins Terminal wechseln.",
  },
  es: {
    continuedNewChat: "Se continuó en un chat nuevo. El contexto anterior está vinculado.",
    movedServingRoute: "Se cambió a otra ruta de servicio. Se conservó el contexto de la conversación.",
    continueNewChat: "Continuar en un chat nuevo",
    continueElsewhere: "Continuar en otro lugar",
    transcriptViewRunning: "El agente está trabajando en la terminal. Cambia a la terminal para responder o aprobar.",
    transcriptViewIdle: "Reflejando la sesión de la terminal. Cambia a la terminal para responder, aprobar o ejecutar comandos.",
  },
  fr: {
    continuedNewChat: "La conversation continue dans un nouveau chat. Le contexte précédent est lié.",
    movedServingRoute: "Passage à une autre route de service. Le contexte de la conversation a été conservé.",
    continueNewChat: "Continuer dans un nouveau chat",
    continueElsewhere: "Continuer ailleurs",
    transcriptViewRunning: "L’agent travaille dans le terminal. Passez au terminal pour répondre ou approuver.",
    transcriptViewIdle: "Miroir de la session du terminal. Passez au terminal pour répondre, approuver ou lancer des commandes.",
  },
  it: {
    continuedNewChat: "Continuazione in una nuova chat. Il contesto precedente è collegato.",
    movedServingRoute: "Passaggio a un altro percorso di servizio. Il contesto della conversazione è stato mantenuto.",
    continueNewChat: "Continua in una nuova chat",
    continueElsewhere: "Continua altrove",
    transcriptViewRunning: "L’agente sta lavorando nel terminale. Passa al terminale per rispondere o approvare.",
    transcriptViewIdle: "Rispecchia la sessione del terminale. Passa al terminale per rispondere, approvare o eseguire comandi.",
  },
  da: {
    continuedNewChat: "Fortsat i en ny chat. Den tidligere kontekst er knyttet til.",
    movedServingRoute: "Flyttet til en anden serveringsrute. Samtalens kontekst blev bevaret.",
    continueNewChat: "Fortsæt i ny chat",
    continueElsewhere: "Fortsæt et andet sted",
    transcriptViewRunning: "Agenten arbejder i terminalen. Skift til terminalen for at svare eller godkende.",
    transcriptViewIdle: "Spejler terminalsessionen. Skift til terminalen for at svare, godkende eller køre kommandoer.",
  },
  pl: {
    continuedNewChat: "Kontynuowano w nowym czacie. Poprzedni kontekst jest połączony.",
    movedServingRoute: "Przeniesiono na inną trasę obsługi. Kontekst rozmowy został zachowany.",
    continueNewChat: "Kontynuuj w nowym czacie",
    continueElsewhere: "Kontynuuj gdzie indziej",
    transcriptViewRunning: "Agent pracuje w terminalu. Przełącz się do terminala, aby odpowiedzieć lub zatwierdzić.",
    transcriptViewIdle: "Odzwierciedla sesję terminala. Przełącz się do terminala, aby odpowiedzieć, zatwierdzić lub uruchomić polecenia.",
  },
  ru: {
    continuedNewChat: "Продолжено в новом чате. Предыдущий контекст связан.",
    movedServingRoute: "Переключено на другой маршрут обслуживания. Контекст разговора сохранён.",
    continueNewChat: "Продолжить в новом чате",
    continueElsewhere: "Продолжить в другом месте",
    transcriptViewRunning: "Агент работает в терминале. Перейдите в терминал, чтобы ответить или подтвердить.",
    transcriptViewIdle: "Отображается сеанс терминала. Перейдите в терминал, чтобы ответить, подтвердить или выполнить команды.",
  },
  bs: {
    continuedNewChat: "Nastavljeno u novom chatu. Prethodni kontekst je povezan.",
    movedServingRoute: "Prebačeno na drugu servisnu rutu. Kontekst razgovora je sačuvan.",
    continueNewChat: "Nastavi u novom chatu",
    continueElsewhere: "Nastavi drugdje",
    transcriptViewRunning: "Agent radi u terminalu. Pređite u terminal da odgovorite ili odobrite.",
    transcriptViewIdle: "Prikazuje se sesija terminala. Pređite u terminal da odgovorite, odobrite ili pokrenete komande.",
  },
  ar: {
    continuedNewChat: "تمت المتابعة في محادثة جديدة. السياق السابق مرتبط.",
    movedServingRoute: "تم الانتقال إلى مسار خدمة آخر. تم الاحتفاظ بسياق المحادثة.",
    continueNewChat: "المتابعة في محادثة جديدة",
    continueElsewhere: "المتابعة في مكان آخر",
    transcriptViewRunning: "الوكيل يعمل في الطرفية. انتقل إلى الطرفية للرد أو الموافقة.",
    transcriptViewIdle: "يتم عرض جلسة الطرفية. انتقل إلى الطرفية للرد أو الموافقة أو تشغيل الأوامر.",
  },
  no: {
    continuedNewChat: "Fortsatt i en ny chat. Tidligere kontekst er koblet til.",
    movedServingRoute: "Flyttet til en annen serveringsrute. Samtalekonteksten ble bevart.",
    continueNewChat: "Fortsett i ny chat",
    continueElsewhere: "Fortsett et annet sted",
    transcriptViewRunning: "Agenten jobber i terminalen. Bytt til terminalen for å svare eller godkjenne.",
    transcriptViewIdle: "Speiler terminaløkten. Bytt til terminalen for å svare, godkjenne eller kjøre kommandoer.",
  },
  "pt-BR": {
    continuedNewChat: "Continuado em um novo chat. O contexto anterior está vinculado.",
    movedServingRoute: "Movido para outra rota de atendimento. O contexto da conversa foi preservado.",
    continueNewChat: "Continuar em um novo chat",
    continueElsewhere: "Continuar em outro lugar",
    transcriptViewRunning: "O agente está trabalhando no terminal. Mude para o terminal para responder ou aprovar.",
    transcriptViewIdle: "Espelhando a sessão do terminal. Mude para o terminal para responder, aprovar ou executar comandos.",
  },
  th: {
    continuedNewChat: "ดำเนินการต่อในแชทใหม่แล้ว โดยเชื่อมโยงบริบทก่อนหน้าไว้",
    movedServingRoute: "ย้ายไปยังเส้นทางการให้บริการอื่นแล้ว โดยยังคงบริบทการสนทนาไว้",
    continueNewChat: "ดำเนินการต่อในแชทใหม่",
    continueElsewhere: "ดำเนินการต่อที่อื่น",
    transcriptViewRunning: "เอเจนต์กำลังทำงานในเทอร์มินัล สลับไปที่เทอร์มินัลเพื่อตอบกลับหรืออนุมัติ",
    transcriptViewIdle: "กำลังแสดงเซสชันเทอร์มินัล สลับไปที่เทอร์มินัลเพื่อตอบกลับ อนุมัติ หรือเรียกใช้คำสั่ง",
  },
  tr: {
    continuedNewChat: "Yeni bir sohbette devam edildi. Önceki bağlam bağlantılı.",
    movedServingRoute: "Başka bir hizmet rotasına geçildi. Konuşma bağlamı korundu.",
    continueNewChat: "Yeni sohbette devam et",
    continueElsewhere: "Başka yerde devam et",
    transcriptViewRunning: "Ajan terminalde çalışıyor. Yanıtlamak veya onaylamak için terminale geçin.",
    transcriptViewIdle: "Terminal oturumu yansıtılıyor. Yanıtlamak, onaylamak veya komut çalıştırmak için terminale geçin.",
  },
  km: {
    continuedNewChat: "បានបន្តនៅក្នុងការជជែកថ្មី។ បរិបទមុនត្រូវបានភ្ជាប់។",
    movedServingRoute: "បានប្តូរទៅផ្លូវបម្រើផ្សេង។ បរិបទនៃការសន្ទនាត្រូវបានរក្សាទុក។",
    continueNewChat: "បន្តក្នុងការជជែកថ្មី",
    continueElsewhere: "បន្តនៅកន្លែងផ្សេង",
    transcriptViewRunning: "ភ្នាក់ងារកំពុងធ្វើការនៅក្នុងទែមីណាល់។ ប្ដូរទៅទែមីណាល់ដើម្បីឆ្លើយតប ឬអនុម័ត។",
    transcriptViewIdle: "កំពុងបង្ហាញវគ្គទែមីណាល់។ ប្ដូរទៅទែមីណាល់ដើម្បីឆ្លើយតប អនុម័ត ឬដំណើរការពាក្យបញ្ជា។",
  },
  uk: {
    continuedNewChat: "Продовжено в новому чаті. Попередній контекст пов’язано.",
    movedServingRoute: "Перемкнено на інший маршрут обслуговування. Контекст розмови збережено.",
    continueNewChat: "Продовжити в новому чаті",
    continueElsewhere: "Продовжити в іншому місці",
    transcriptViewRunning: "Агент працює в терміналі. Перейдіть у термінал, щоб відповісти або підтвердити.",
    transcriptViewIdle: "Відображається сеанс термінала. Перейдіть у термінал, щоб відповісти, підтвердити або виконати команди.",
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
