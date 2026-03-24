> Esta tradução foi gerada pelo Claude. Se você tiver sugestões de melhoria, abra um PR.

<h1 align="center">cmux</h1>
<p align="center">Um terminal macOS baseado em Ghostty com abas verticais e notificações para agentes de programação com IA</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Baixar cmux para macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | Português (Brasil) | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="Captura de tela do cmux" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Vídeo de demonstração</a> · <a href="https://cmux.com/blog/zen-of-cmux">O Zen do cmux</a>
</p>

## Recursos

<table>
<tr>
<td width="40%" valign="middle">
<h3>Anéis de notificação</h3>
Os painéis recebem um anel azul e as abas acendem quando agentes de programação precisam da sua atenção
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Anéis de notificação" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Painel de notificações</h3>
Veja todas as notificações pendentes em um só lugar, vá direto para a mais recente não lida
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Badge de notificação na barra lateral" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Navegador integrado</h3>
Divida um navegador ao lado do seu terminal com uma API programável portada do <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Navegador integrado" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Abas verticais + horizontais</h3>
A barra lateral mostra o branch do git, status/número do PR vinculado, diretório de trabalho, portas em escuta e texto da última notificação. Divida horizontal e verticalmente.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Abas verticais e painéis divididos" width="100%" />
</td>
</tr>
</table>

- **Programável** — CLI e socket API para criar workspaces, dividir painéis, enviar teclas e automatizar o navegador
- **App nativo macOS** — Construído com Swift e AppKit, não Electron. Inicialização rápida, baixo consumo de memória.
- **Compatível com Ghostty** — Lê sua configuração existente em `~/.config/ghostty/config` para temas, fontes e cores
- **Acelerado por GPU** — Alimentado por libghostty para renderização suave

## Instalação

### DMG (recomendado)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Baixar cmux para macOS" width="180" />
</a>

Abra o `.dmg` e arraste o cmux para a pasta Aplicativos. O cmux se atualiza automaticamente via Sparkle, então você só precisa baixar uma vez.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

Para atualizar depois:

```bash
brew upgrade --cask cmux
```

Na primeira execução, o macOS pode pedir para você confirmar a abertura de um app de um desenvolvedor identificado. Clique em **Abrir** para continuar.

## Por que o cmux?

Eu executo muitas sessões de Claude Code e Codex em paralelo. Eu estava usando o Ghostty com vários painéis divididos e contando com as notificações nativas do macOS para saber quando um agente precisava de mim. Mas o corpo da notificação do Claude Code é sempre apenas "Claude is waiting for your input" sem contexto, e com abas suficientes abertas eu não conseguia nem ler os títulos mais.

Eu tentei alguns orquestradores de código, mas a maioria era apps Electron/Tauri e o desempenho me incomodava. Eu também prefiro o terminal, já que orquestradores GUI te prendem no fluxo de trabalho deles. Então eu construí o cmux como um app nativo macOS em Swift/AppKit. Ele usa o libghostty para renderização do terminal e lê sua configuração existente do Ghostty para temas, fontes e cores.

As principais adições são a barra lateral e o sistema de notificações. A barra lateral tem abas verticais que mostram o branch do git, status/número do PR vinculado, diretório de trabalho, portas em escuta e o texto da última notificação para cada workspace. O sistema de notificações captura sequências do terminal (OSC 9/99/777) e tem uma CLI (`cmux notify`) que você pode conectar aos hooks de agentes para Claude Code, OpenCode, etc. Quando um agente está esperando, seu painel recebe um anel azul e a aba acende na barra lateral, para que eu possa ver qual precisa de mim entre divisões e abas. Cmd+Shift+U pula para o mais recente não lido.

O navegador integrado tem uma API programável portada do [agent-browser](https://github.com/vercel-labs/agent-browser). Agentes podem capturar a árvore de acessibilidade, obter referências de elementos, clicar, preencher formulários e executar JS. Você pode dividir um painel de navegador ao lado do seu terminal e fazer o Claude Code interagir diretamente com seu servidor de desenvolvimento.

Tudo é programável através da CLI e socket API — criar workspaces/abas, dividir painéis, enviar teclas, abrir URLs no navegador.

## O Zen do cmux

O cmux não é prescritivo sobre como os desenvolvedores usam suas ferramentas. É um terminal e navegador com uma CLI, e o resto é com você.

O cmux é uma primitiva, não uma solução. Ele te dá um terminal, um navegador, notificações, workspaces, divisões, abas e uma CLI para controlar tudo isso. O cmux não te força a usar agentes de programação de uma forma específica. O que você constrói com as primitivas é seu.

Os melhores desenvolvedores sempre construíram suas próprias ferramentas. Ninguém descobriu ainda a melhor forma de trabalhar com agentes, e as equipes construindo produtos fechados definitivamente também não. Os desenvolvedores mais próximos de suas próprias bases de código vão descobrir primeiro.

Dê a um milhão de desenvolvedores primitivas combináveis e eles coletivamente encontrarão os fluxos de trabalho mais eficientes mais rápido do que qualquer equipe de produto poderia projetar de cima para baixo.

## Documentação

Para mais informações sobre como configurar o cmux, [acesse nossa documentação](https://cmux.com/docs/getting-started?utm_source=readme).

## Atalhos de Teclado

### Áreas de Trabalho

| Atalho | Ação |
|----------|--------|
| ⌘ N | Novo workspace |
| ⌘ 1–8 | Ir para workspace 1–8 |
| ⌘ 9 | Ir para último workspace |
| ⌃ ⌘ ] | Próximo workspace |
| ⌃ ⌘ [ | Workspace anterior |
| ⌘ ⇧ W | Fechar workspace |
| ⌘ ⇧ R | Renomear workspace |
| ⌘ B | Alternar barra lateral |

### Superfícies

| Atalho | Ação |
|----------|--------|
| ⌘ T | Nova surface |
| ⌘ ⇧ ] | Próxima surface |
| ⌘ ⇧ [ | Surface anterior |
| ⌃ Tab | Próxima surface |
| ⌃ ⇧ Tab | Surface anterior |
| ⌃ 1–8 | Ir para surface 1–8 |
| ⌃ 9 | Ir para última surface |
| ⌘ W | Fechar surface |

### Painéis Divididos

| Atalho | Ação |
|----------|--------|
| ⌘ D | Dividir à direita |
| ⌘ ⇧ D | Dividir para baixo |
| ⌥ ⌘ ← → ↑ ↓ | Focar painel direcionalmente |
| ⌘ ⇧ H | Piscar painel focado |

### Navegador

Os atalhos de ferramentas do desenvolvedor do navegador seguem os padrões do Safari e podem ser personalizados em `Configurações → Atalhos de Teclado`.

| Atalho | Ação |
|----------|--------|
| ⌘ ⇧ L | Abrir navegador em divisão |
| ⌘ L | Focar barra de endereço |
| ⌘ [ | Voltar |
| ⌘ ] | Avançar |
| ⌘ R | Recarregar página |
| ⌥ ⌘ I | Alternar Ferramentas do Desenvolvedor (padrão Safari) |
| ⌥ ⌘ C | Mostrar Console JavaScript (padrão Safari) |

### Notificações

| Atalho | Ação |
|----------|--------|
| ⌘ I | Mostrar painel de notificações |
| ⌘ ⇧ U | Ir para última não lida |

### Busca

| Atalho | Ação |
|----------|--------|
| ⌘ F | Buscar |
| ⌘ G / ⌘ ⇧ G | Buscar próximo / anterior |
| ⌘ ⇧ F | Ocultar barra de busca |
| ⌘ E | Usar seleção para busca |

### Terminal

| Atalho | Ação |
|----------|--------|
| ⌘ K | Limpar histórico de rolagem |
| ⌘ C | Copiar (com seleção) |
| ⌘ V | Colar |
| ⌘ + / ⌘ - | Aumentar / diminuir tamanho da fonte |
| ⌘ 0 | Redefinir tamanho da fonte |

### Janela

| Atalho | Ação |
|----------|--------|
| ⌘ ⇧ N | Nova janela |
| ⌘ , | Configurações |
| ⌘ ⇧ , | Recarregar configuração |
| ⌘ Q | Sair |

## Builds Noturnos

[Baixar cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

O cmux NIGHTLY é um app separado com seu próprio bundle ID, então roda ao lado da versão estável. Construído automaticamente a partir do último commit em `main` e se atualiza automaticamente via seu próprio feed Sparkle.

## Restauração de sessão (comportamento atual)

Ao reiniciar, o cmux atualmente restaura apenas o layout do app e metadados:
- Layout de janelas/workspaces/painéis
- Diretórios de trabalho
- Histórico de rolagem do terminal (melhor esforço)
- URL do navegador e histórico de navegação

O cmux **não** restaura o estado de processos ativos dentro de apps de terminal. Por exemplo, sessões ativas de Claude Code/tmux/vim não são retomadas após reiniciar ainda.

## Histórico de Estrelas

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## Contribuindo

Formas de participar:

- Siga-nos no X para atualizações [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen), e [@austinywang](https://x.com/austinywang)
- Participe da conversa no [Discord](https://discord.gg/xsgFEVrWCZ)
- Crie e participe de [issues no GitHub](https://github.com/manaflow-ai/cmux/issues) e [discussões](https://github.com/manaflow-ai/cmux/discussions)
- Nos conte o que você está construindo com o cmux

## Comunidade

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Edição do Fundador

O cmux é gratuito, open source, e sempre será. Se você gostaria de apoiar o desenvolvimento e ter acesso antecipado ao que está por vir:

**[Obter Edição do Fundador](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Solicitações de recursos/correções de bugs priorizadas**
- **Acesso antecipado: cmux AI que te dá contexto sobre cada workspace, aba e painel**
- **Acesso antecipado: app iOS com terminais sincronizados entre desktop e celular**
- **Acesso antecipado: VMs na nuvem**
- **Acesso antecipado: Modo de voz**
- **Meu iMessage/WhatsApp pessoal**

## Licença

cmux é open source sob [AGPL-3.0-or-later](LICENSE).

Se sua organização não puder cumprir a AGPL, uma licença comercial está disponível. Entre em contato com [founders@manaflow.com](mailto:founders@manaflow.com) para detalhes.
