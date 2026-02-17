> Questa traduzione è stata generata da Claude. Se hai suggerimenti per migliorarla, apri una PR.

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | Italiano | <a href="README.da.md">Dansk</a> | <a href="README.ja.md">日本語</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a>
</p>

<h1 align="center">cmux</h1>
<p align="center">Un terminale macOS basato su Ghostty con schede verticali e notifiche per agenti di programmazione AI</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Scarica cmux per macOS" width="180" />
  </a>
</p>

<p align="center">
  <img src="./docs/assets/screenshot.png" alt="Screenshot di cmux" width="900" />
</p>

## Funzionalità

- **Schede verticali** — La barra laterale mostra il branch git, la directory di lavoro, le porte in ascolto e il testo dell'ultima notifica
- **Anelli di notifica** — I pannelli ricevono un anello blu e le schede si illuminano quando gli agenti AI (Claude Code, OpenCode) richiedono la tua attenzione
- **Pannello notifiche** — Visualizza tutte le notifiche in sospeso in un unico posto, salta alla più recente non letta
- **Pannelli divisi** — Divisioni orizzontali e verticali
- **Browser integrato** — Dividi un browser accanto al tuo terminale con un'API scriptabile derivata da [agent-browser](https://github.com/vercel-labs/agent-browser)
- **Scriptabile** — CLI e socket API per creare workspace, dividere pannelli, inviare sequenze di tasti e automatizzare il browser
- **App macOS nativa** — Costruita con Swift e AppKit, non Electron. Avvio rapido, basso consumo di memoria.
- **Compatibile con Ghostty** — Legge la tua configurazione esistente `~/.config/ghostty/config` per temi, font e colori
- **Accelerazione GPU** — Alimentato da libghostty per un rendering fluido

## Installazione

### DMG (consigliato)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Scarica cmux per macOS" width="180" />
</a>

Apri il file `.dmg` e trascina cmux nella cartella Applicazioni. cmux si aggiorna automaticamente tramite Sparkle, quindi devi scaricarlo solo una volta.

### Homebrew

```bash
brew tap manaflow-ai/cmux
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

Le aggiunte principali sono la barra laterale e il sistema di notifiche. La barra laterale ha schede verticali che mostrano il branch git, la directory di lavoro, le porte in ascolto e il testo dell'ultima notifica per ogni workspace. Il sistema di notifiche rileva le sequenze terminale (OSC 9/99/777) e ha un CLI (`cmux notify`) che puoi collegare agli hook degli agenti per Claude Code, OpenCode, ecc. Quando un agente è in attesa, il suo pannello riceve un anello blu e la scheda si illumina nella barra laterale, così posso capire quale ha bisogno di me tra divisioni e schede. Cmd+Shift+U salta alla più recente non letta.

Il browser integrato ha un'API scriptabile derivata da [agent-browser](https://github.com/vercel-labs/agent-browser). Gli agenti possono acquisire l'albero di accessibilità, ottenere riferimenti agli elementi, fare clic, compilare moduli e valutare JS. Puoi dividere un pannello browser accanto al tuo terminale e far interagire Claude Code direttamente con il tuo server di sviluppo.

Tutto è scriptabile attraverso il CLI e la socket API — creare workspace/schede, dividere pannelli, inviare sequenze di tasti, aprire URL nel browser.

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
| ⌘ B | Mostra/nascondi barra laterale |

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

| Scorciatoia | Azione |
|----------|--------|
| ⌘ ⇧ L | Apri browser in divisione |
| ⌘ L | Focus sulla barra degli indirizzi |
| ⌘ [ | Indietro |
| ⌘ ] | Avanti |
| ⌘ R | Ricarica pagina |
| ⌥ ⌘ I | Apri Strumenti di Sviluppo |

### Notifiche

| Scorciatoia | Azione |
|----------|--------|
| ⌘ I | Mostra pannello notifiche |
| ⌘ ⇧ U | Vai all'ultima non letta |

### Cerca

| Scorciatoia | Azione |
|----------|--------|
| ⌘ F | Cerca |
| ⌘ G / ⌘ ⇧ G | Trova successivo / precedente |
| ⌘ ⇧ F | Nascondi barra di ricerca |
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
| ⌘ , | Impostazioni |
| ⌘ ⇧ , | Ricarica configurazione |
| ⌘ Q | Esci |

## Licenza

Questo progetto è distribuito sotto la GNU Affero General Public License v3.0 o successiva (`AGPL-3.0-or-later`).

Vedi `LICENSE` per il testo completo.
