> Questa traduzione è stata generata da Claude. Se hai suggerimenti per migliorarla, apri una PR.

<h1 align="center">cmux</h1>
<p align="center">Un terminale macOS basato su Ghostty con schede verticali e notifiche per agenti di programmazione AI</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Scarica cmux per macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.vi.md">Tiếng Việt</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | Italiano | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="Screenshot di cmux" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Video demo</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## Funzionalità

<table>
<tr>
<td width="40%" valign="middle">
<h3>Anelli di notifica</h3>
I pannelli ricevono un anello blu e le schede si illuminano quando gli agenti di programmazione richiedono la tua attenzione
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Anelli di notifica" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Pannello notifiche</h3>
Visualizza tutte le notifiche in sospeso in un unico posto, salta alla più recente non letta
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Badge notifica nella barra laterale" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Browser integrato</h3>
Dividi un browser accanto al tuo terminale con un'API scriptabile derivata da <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Browser integrato" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Schede verticali + orizzontali</h3>
La barra laterale mostra il branch git, lo stato/numero della PR collegata, la directory di lavoro, le porte in ascolto e il testo dell'ultima notifica. Dividi orizzontalmente e verticalmente.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Schede verticali e pannelli divisi" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> crea un workspace per una macchina remota. I pannelli del browser vengono instradati attraverso la rete remota, quindi localhost funziona direttamente. Trascina un'immagine in una sessione remota per caricarla via scp.
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> avvia la modalità teammate di Claude Code con un solo comando. I teammate appaiono come divisioni native con metadati nella barra laterale e notifiche. Non serve tmux.
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **Import browser** — Importa cookie, cronologia e sessioni da Chrome, Firefox, Arc e oltre 20 browser in modo che i pannelli del browser partano già autenticati
- **Comandi personalizzati** — Definisci azioni specifiche per il progetto in [`cmux.json`](https://cmux.com/docs/custom-commands) che si lanciano dalla palette dei comandi
- **Scriptabile** — CLI e socket API per creare workspace, dividere pannelli, inviare sequenze di tasti e automatizzare il browser
- **App macOS nativa** — Costruita con Swift e AppKit, non Electron. Avvio rapido, basso consumo di memoria.
- **Compatibile con Ghostty** — Legge la tua configurazione esistente `~/.config/ghostty/config` per temi, font e colori
- **Accelerazione GPU** — Alimentato da libghostty per un rendering fluido
- **Scorciatoie da tastiera** — [Scorciatoie estese](https://cmux.com/docs/keyboard-shortcuts) per workspace, divisioni, browser e altro
- **Open source** — Gratuito e con licenza GPL

## Installazione

### DMG (consigliato)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Scarica cmux per macOS" width="180" />
</a>

Apri il file `.dmg` e trascina cmux nella cartella Applicazioni. cmux si aggiorna automaticamente tramite Sparkle, quindi devi scaricarlo solo una volta.

### Homebrew

```bash
brew install --cask cmux
```

Per aggiornare in seguito:

```bash
brew upgrade --cask cmux
```

Al primo avvio, macOS potrebbe chiederti di confermare l'apertura di un'app da uno sviluppatore identificato. Fai clic su **Apri** per procedere.

## Perché cmux?

Eseguo molte sessioni di Claude Code e Codex in parallelo. Usavo Ghostty con un mucchio di pannelli divisi, e mi affidavo alle notifiche native di macOS per sapere quando un agente aveva bisogno di me. Ma il corpo della notifica di Claude Code è sempre solo "Claude is waiting for your input" senza contesto, e con abbastanza schede aperte non riuscivo nemmeno più a leggere i titoli.

Ho provato alcuni orchestratori di codifica, ma la maggior parte erano app Electron/Tauri e le prestazioni mi infastidivano. Inoltre preferisco semplicemente il terminale dato che gli orchestratori con interfaccia grafica ti vincolano al loro flusso di lavoro. Così ho costruito cmux come app macOS nativa in Swift/AppKit. Usa libghostty per il rendering del terminale e legge la tua configurazione Ghostty esistente per temi, font e colori.

Le aggiunte principali sono la barra laterale e il sistema di notifiche. La barra laterale ha schede verticali che mostrano il branch git, lo stato/numero della PR collegata, la directory di lavoro, le porte in ascolto e il testo dell'ultima notifica per ogni workspace. Il sistema di notifiche rileva le sequenze terminale (OSC 9/99/777) e ha un CLI (`cmux notify`) che puoi collegare agli hook degli agenti per Claude Code, OpenCode, ecc. Quando un agente è in attesa, il suo pannello riceve un anello blu e la scheda si illumina nella barra laterale, così posso capire quale ha bisogno di me tra divisioni e schede. Cmd+Shift+U salta alla più recente non letta.

Il browser integrato ha un'API scriptabile derivata da [agent-browser](https://github.com/vercel-labs/agent-browser). Gli agenti possono acquisire l'albero di accessibilità, ottenere riferimenti agli elementi, fare clic, compilare moduli e valutare JS. Puoi dividere un pannello browser accanto al tuo terminale e far interagire Claude Code direttamente con il tuo server di sviluppo.

Tutto è scriptabile attraverso il CLI e la socket API — creare workspace/schede, dividere pannelli, inviare sequenze di tasti, aprire URL nel browser.

## The Zen of cmux

cmux non prescrive come gli sviluppatori usano i propri strumenti. È un terminale e un browser con un CLI, il resto dipende da te.

cmux è una primitiva, non una soluzione. Ti dà un terminale, un browser, notifiche, workspace, divisioni, schede e un CLI per controllare tutto. cmux non ti obbliga a usare gli agenti di programmazione in un modo predefinito. Quello che costruisci con le primitive è tuo.

I migliori sviluppatori hanno sempre costruito i propri strumenti. Nessuno ha ancora trovato il modo migliore di lavorare con gli agenti, e i team che costruiscono prodotti chiusi non l'hanno trovato nemmeno loro. Gli sviluppatori più vicini alle proprie basi di codice lo troveranno per primi.

Date a un milione di sviluppatori primitive componibili e troveranno collettivamente i flussi di lavoro più efficienti più velocemente di quanto qualsiasi team di prodotto potrebbe progettare dall'alto.

## Documentazione

Per maggiori informazioni su come configurare cmux, [consulta la nostra documentazione](https://cmux.com/docs/getting-started?utm_source=readme).

## Scorciatoie da Tastiera

### Workspace

| Scorciatoia | Azione |
|----------|--------|
| ⌘ N | Nuovo workspace |
| ⌘ 1–8 | Vai al workspace 1–8 |
| ⌘ 9 | Vai all'ultimo workspace |
| ⌃ ⌘ ] | Workspace successivo |
| ⌃ ⌘ [ | Workspace precedente |
| ⌘ ⇧ W | Chiudi workspace |
| ⌘ ⇧ R | Rinomina workspace |
| ⌥ ⌘ E | Modifica descrizione del workspace |
| ⌘ B | Mostra/nascondi barra laterale |
| ⌥ ⌘ B | Mostra/nascondi barra laterale destra |
| ⌘ ⇧ E | Attiva/disattiva il focus della barra laterale destra |

### Superfici

| Scorciatoia | Azione |
|----------|--------|
| ⌘ T | Nuova superficie |
| ⌘ ⇧ ] | Superficie successiva |
| ⌘ ⇧ [ | Superficie precedente |
| ⌃ Tab | Superficie successiva |
| ⌃ ⇧ Tab | Superficie precedente |
| ⌃ 1–8 | Vai alla superficie 1–8 |
| ⌃ 9 | Vai all'ultima superficie |
| ⌘ W | Chiudi superficie |

### Pannelli Divisi

| Scorciatoia | Azione |
|----------|--------|
| ⌘ D | Dividi a destra |
| ⌘ ⇧ D | Dividi in basso |
| ⌥ ⌘ ← → ↑ ↓ | Sposta il focus direzionalmente |
| ⌘ ⇧ H | Lampeggia pannello focalizzato |

### Browser

Le scorciatoie degli strumenti di sviluppo del browser seguono i valori predefiniti di Safari e sono personalizzabili in `Impostazioni → Scorciatoie da tastiera`.
Le scorciatoie di navigazione della palette dei comandi, inclusa ⌃ P, sono anch'esse personalizzabili e possono essere cancellate in modo che la pressione raggiunga il terminale attivo.

| Scorciatoia | Azione |
|----------|--------|
| ⌘ ⇧ L | Apri browser in divisione |
| ⌘ L | Focus sulla barra degli indirizzi |
| ⌘ [ | Indietro |
| ⌘ ] | Avanti |
| ⌘ R | Ricarica pagina |
| ⌥ ⌘ I | Mostra/Nascondi Strumenti di Sviluppo (predefinito Safari) |
| ⌥ ⌘ C | Mostra Console JavaScript (predefinito Safari) |

### Notifiche

| Scorciatoia | Azione |
|----------|--------|
| ⌘ I | Mostra pannello notifiche |
| ⌘ ⇧ U | Vai all'ultima non letta |
| ⌥ ⌘ U | Attiva/disattiva lo stato non letto dell'elemento corrente |
| ⌃ ⌘ U | Segna l'elemento corrente come la non letta più vecchia e salta alla successiva più recente non letta |

### Cerca

| Scorciatoia | Azione |
|----------|--------|
| ⌘ F | Cerca |
| ⌘ ⇧ F | Cerca nella directory |
| ⌘ G / ⌥ ⌘ G | Trova successivo / precedente |
| ⌥ ⌘ ⇧ F | Nascondi barra di ricerca |
| ⌘ E | Usa selezione per la ricerca |

### Terminale

| Scorciatoia | Azione |
|----------|--------|
| ⌘ K | Cancella scrollback |
| ⌘ C | Copia (con selezione) |
| ⌘ V | Incolla |
| ⌘ + / ⌘ - | Aumenta / diminuisci dimensione font |
| ⌘ 0 | Ripristina dimensione font |

### Finestra

| Scorciatoia | Azione |
|----------|--------|
| ⌘ ⇧ N | Nuova finestra |
| ⌘ ⇧ O | Riapri sessione precedente |
| ⌘ , | Impostazioni |
| ⌘ ⇧ , | Ricarica configurazione |
| ⌘ Q | Esci |

## Build Nightly

[Scarica cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY è un'app separata con il proprio bundle ID, quindi funziona in parallelo alla versione stabile. Compilata automaticamente dall'ultimo commit `main` e aggiornata automaticamente tramite il proprio feed Sparkle.

Segnala i bug delle nightly su [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) o in [#nightly-bugs su Discord](https://discord.gg/xsgFEVrWCZ).

## Ripristino sessione

Alla chiusura, cmux salva la sessione corrente. Al riavvio, cmux ripristina lo stato
gestito dall'app:
- Layout di finestre/workspace/pannelli
- Directory di lavoro
- Scrollback del terminale (best effort)
- URL del browser e cronologia di navigazione

cmux non crea checkpoint per processi attivi arbitrari. tmux, vim, shell e app terminale
non supportate si riaprono come terminali normali.

Le sessioni degli agent supportati possono riprendere quando gli hook hanno salvato un ID
sessione nativo. Installa gli hook dopo aver installato il CLI dell'agente in modo che il suo
binario sia nel `PATH`:

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup` installa gli agent supportati che trova e stampa un riepilogo
degli agent saltati. Le integrazioni di ripristino supportate includono Claude Code, Codex,
Grok, OpenCode, Pi, Amp, Cursor CLI, Gemini, Rovo Dev, Copilot, CodeBuddy,
Factory e Qoder. Claude Code è gestito dal wrapper Claude di cmux quando l'integrazione
Claude è abilitata nelle Impostazioni.

Utenti avanzati e integrazioni possono associare un comando di ripristino personalizzato alla
surface del terminale corrente. È utile per strumenti con stato persistente proprio, come
sessioni tmux o CLI agent personalizzate:

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

L'associazione resta legata alla surface di cmux. Le associazioni create dal CLI pubblico o dal
socket vengono salvate per ispezione e ripristino manuale, a meno che tu non approvi un prefisso
di comando firmato per il ripristino automatico. I prefissi approvati sono anche legati alla
directory di lavoro e ai valori esatti dell'ambiente, quando presenti. Esamina o modifica le
approvazioni in **Impostazioni > Terminale > Comandi di ripristino**. cmux esegue automaticamente
solo le associazioni di resume che marca come attendibili, per esempio quelle tmux rilevate dai
processi attivi o i prefissi approvati dall'utente. Le chiavi di ambiente sensibili, come token,
password, segreti e chiavi API, vengono scartate prima di salvare un'associazione di resume.

Per mantenere inattivi i terminali degli agent ripristinati invece di eseguire automaticamente i loro comandi di ripristino,
disattiva **Impostazioni > Terminale > Riprendi sessioni agent alla riapertura** o imposta questo in
`~/.config/cmux/cmux.json`:

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

Questo disattiva solo i comandi di ripristino automatico degli agent. cmux continua a ripristinare il layout salvato,
le directory di lavoro, lo scrollback e la cronologia del browser.

Se devi riapplicare manualmente l'ultima istantanea salvata, usa:
- `File > Riapri sessione precedente`
- `⌘ ⇧ O`
- `cmux restore-session`

Internamente, cmux scrive un'istantanea versionata in
`~/Library/Application Support/cmux/` e gli hook degli agent scrivono le mappature di sessione
in `~/.cmuxterm/`. Al ripristino, cmux ricostruisce prima il layout, poi esegue il comando
di ripristino nativo dell'agent supportato quando il ripristino automatico degli agent è abilitato.

Leggi la guida completa su <https://cmux.com/docs/session-restore>.

## FAQ

### Che relazione c'è tra cmux e Ghostty?

cmux non è un fork di Ghostty. Usa [libghostty](https://github.com/ghostty-org/ghostty) come libreria per il rendering del terminale, allo stesso modo in cui le app usano WebKit per le viste web. Ghostty è un terminale autonomo; cmux è un'app diversa costruita sopra il suo motore di rendering.

### Quali piattaforme supporta?

Solo macOS, per ora. cmux è un'app nativa Swift + AppKit.

### C'è un'app iOS?

Sì, in beta. Associa il tuo iPhone al tuo Mac dalla finestra Mobile Connect e connettiti ai tuoi terminali dal telefono, con inoltro opzionale delle notifiche del terminale. È distribuita su TestFlight come cmux BETA. Consulta la [documentazione iOS](https://cmux.com/docs/ios).

### Con quali agenti di programmazione funziona cmux?

Con tutti. cmux è un terminale, quindi qualsiasi agente che gira in un terminale funziona da subito: Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline, Cursor Agent e qualsiasi altra cosa tu possa lanciare dalla riga di comando.

### cmux può orchestrare più agenti e subagenti?

Sì. Quando un agente genera subagenti o teammate, cmux li trasforma in pannelli e divisioni native invece che in processi nascosti in background. Supporta [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams) e l'orchestrazione multi-modello di [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode), così ogni agente di un'esecuzione è visibile e controllabile.

### Posso usare cmux con macchine remote?

Sì. Apri workspace tramite SSH e connettiti a sessioni tmux remote, così gli agenti possono girare su un host remoto mentre li piloti da cmux. Consulta [SSH e remoto](https://cmux.com/docs/ssh).

### Come funzionano le notifiche?

Quando un processo richiede attenzione, cmux mostra anelli di notifica attorno ai pannelli, badge di non lette nella barra laterale, un popover di notifiche e una notifica desktop di macOS. Queste si attivano automaticamente tramite sequenze di escape del terminale standard (OSC 9/99/777), oppure puoi attivarle con il [CLI di cmux](https://cmux.com/docs/notifications#cli-usage) e gli [hook degli agenti](https://cmux.com/docs/notifications#integration-examples). Funziona qualsiasi agente che supporti gli hook o OSC, inclusi Claude Code, Codex, OpenCode e pi.

### cmux è programmabile?

Sì. Ogni azione è disponibile tramite il CLI di cmux e un socket Unix: creare workspace, aprire pannelli divisi, inviare input, leggere il contenuto dello schermo, fare screenshot e pilotare il browser integrato. Consulta il [riferimento del CLI](https://cmux.com/docs/api) e la documentazione sull'[automazione del browser](https://cmux.com/docs/browser-automation).

### Cosa può fare il browser integrato?

cmux può dividere un vero pannello browser accanto al tuo terminale, ed è completamente programmabile: navigare, acquisire il DOM, fare clic, digitare, valutare JavaScript e leggere l'attività della console e della rete tramite la stessa socket API. Gli agenti lo usano per verificare le proprie modifiche web senza uscire da cmux. Consulta [automazione del browser](https://cmux.com/docs/browser-automation).

### cmux ha le skill?

Sì. Le skill sono flussi di lavoro riutilizzabili che puoi dare a qualsiasi agente in esecuzione in cmux, per cose come il controllo del CLI, l'automazione dei workspace, le impostazioni e le superfici browser. Sfoglia la collezione aperta su [cmux-skills](https://github.com/manaflow-ai/cmux-skills), oppure leggi la [documentazione delle skill](https://cmux.com/docs/skills).

### Posso personalizzare le scorciatoie da tastiera?

Le combinazioni di tasti del terminale vengono lette dal tuo file di configurazione Ghostty (`~/.config/ghostty/config`). Le scorciatoie specifiche di cmux (workspace, divisioni, browser, notifiche) si possono personalizzare nelle Impostazioni. Consulta le [scorciatoie predefinite](https://cmux.com/docs/keyboard-shortcuts) per l'elenco completo.

### Posso personalizzare cmux?

Sì. Il rendering del terminale usa la tua configurazione Ghostty, quindi temi, font, colori e cursore vengono trasferiti direttamente. Le impostazioni proprie di cmux in `~/.config/cmux/cmux.json` controllano la barra laterale, la barra delle schede, i pannelli divisi e il comportamento, e ogni [scorciatoia da tastiera](https://cmux.com/docs/keyboard-shortcuts) è modificabile. Consulta [configurazione](https://cmux.com/docs/configuration).

### Le mie sessioni vengono salvate?

Sì. cmux ripristina le tue finestre, workspace, pannelli, directory di lavoro e scrollback al riavvio, e lo stato sopravvive a un riavvio completo del computer, non solo alla chiusura dell'app. Tornano anche le sessioni degli agenti come Claude Code, Codex e OpenCode. Consulta [ripristino sessione](https://cmux.com/docs/session-restore).

### Come si confronta con tmux?

tmux è un multiplexer di terminale che gira dentro qualsiasi terminale. cmux è un'app macOS nativa con GUI: schede verticali, pannelli divisi, un browser integrato e una socket API, tutto incorporato, senza bisogno di file di configurazione o tasti prefisso. Detto questo, molte persone usano felicemente cmux insieme a SSH e tmux, e cmux può connettersi nativamente alle tue sessioni tmux remote ([beta](https://cmux.com/docs/remote-tmux)).

### cmux è gratuito?

Sì, cmux è gratuito da usare. Il codice sorgente è disponibile su [GitHub](https://github.com/manaflow-ai/cmux).

### Come posso supportare cmux?

cmux è gratuito e open source, e lo sarà sempre. Se vuoi sostenere lo sviluppo e ottenere accesso anticipato a ciò che arriverà, inclusi cmux AI, l'app iOS e le Cloud VM, dai un'occhiata a [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition).

### Ho una richiesta di funzionalità o ho trovato un bug?

Vogliamo saperlo. Apri una [issue](https://github.com/manaflow-ai/cmux/issues) o una [pull request](https://github.com/manaflow-ai/cmux/pulls) su GitHub, oppure [scrivici un'email](mailto:founders@manaflow.com?subject=cmux%20feature%20request).

## Cronologia Stelle

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## Contribuire

Modi per partecipare:

- Seguici su X per aggiornamenti [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen), e [@austinywang](https://x.com/austinywang)
- Unisciti alla conversazione su [Discord](https://discord.gg/xsgFEVrWCZ)
- Crea e partecipa alle [issue su GitHub](https://github.com/manaflow-ai/cmux/issues) e alle [discussioni](https://github.com/manaflow-ai/cmux/discussions)
- Facci sapere cosa stai costruendo con cmux

## Comunità

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

<p>
  <strong>WeChat:</strong> Scansiona il codice QR per unirti alla community.<br />
  <img src="./docs/assets/wechat-community-qr.jpg" alt="Codice QR WeChat per unirti alla community di cmux" width="240" />
</p>

## Edizione Fondatore

cmux è gratuito, open source, e lo sarà sempre. Se vuoi supportare lo sviluppo e ottenere accesso anticipato a ciò che arriverà:

**[Ottieni l'Edizione Fondatore](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Richieste di funzionalità e correzioni di bug prioritarie**
- **Accesso anticipato: cmux AI che ti dà contesto su ogni workspace, scheda e pannello**
- **Accesso anticipato: app iOS con terminali sincronizzati tra desktop e telefono**
- **Accesso anticipato: VM cloud**
- **Accesso anticipato: Modalità vocale**
- **Il mio iMessage/WhatsApp personale**

## Licenza

cmux è open source sotto [GPL-3.0-or-later](LICENSE).

Se la tua organizzazione non può conformarsi alla GPL, è disponibile una licenza commerciale. Contatta [founders@manaflow.com](mailto:founders@manaflow.com) per i dettagli.
