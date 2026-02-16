> Esta traducción fue generada por Claude. Si tienes sugerencias de mejora, abre un PR.

<p align="center"><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | Español | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.ja.md">日本語</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a></p>

<h1 align="center">cmux</h1>
<p align="center">Un terminal macOS basado en Ghostty con pestañas verticales y notificaciones para agentes de programación con IA</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Descargar cmux para macOS" width="180" />
  </a>
</p>

<p align="center">
  <img src="./docs/assets/screenshot.png" alt="Captura de pantalla de cmux" width="900" />
</p>

## Características

- **Pestañas verticales** — La barra lateral muestra la rama de git, el directorio de trabajo, los puertos en escucha y el texto de la última notificación
- **Anillos de notificación** — Los paneles obtienen un anillo azul y las pestañas se iluminan cuando los agentes de IA (Claude Code, OpenCode) necesitan tu atención
- **Panel de notificaciones** — Ve todas las notificaciones pendientes en un solo lugar, salta a la más reciente no leída
- **Paneles divididos** — Divisiones horizontales y verticales
- **Navegador integrado** — Divide un navegador junto a tu terminal con una API programable portada de [agent-browser](https://github.com/vercel-labs/agent-browser)
- **Programable** — CLI y API de socket para crear espacios de trabajo, dividir paneles, enviar pulsaciones de teclas y automatizar el navegador
- **App nativa de macOS** — Construida con Swift y AppKit, no con Electron. Inicio rápido, bajo consumo de memoria.
- **Compatible con Ghostty** — Lee tu configuración existente en `~/.config/ghostty/config` para temas, fuentes y colores
- **Aceleración por GPU** — Impulsado por libghostty para un renderizado fluido

## Instalación

### DMG (recomendado)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Descargar cmux para macOS" width="180" />
</a>

Abre el `.dmg` y arrastra cmux a tu carpeta de Aplicaciones. cmux se actualiza automáticamente a través de Sparkle, así que solo necesitas descargarlo una vez.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

Para actualizar más tarde:

```bash
brew upgrade --cask cmux
```

En el primer inicio, macOS puede pedirte que confirmes la apertura de una app de un desarrollador identificado. Haz clic en **Abrir** para continuar.

## ¿Por qué cmux?

Ejecuto muchas sesiones de Claude Code y Codex en paralelo. Estaba usando Ghostty con un montón de paneles divididos y dependía de las notificaciones nativas de macOS para saber cuándo un agente me necesitaba. Pero el cuerpo de la notificación de Claude Code siempre es solo "Claude is waiting for your input" sin contexto, y con suficientes pestañas abiertas ya ni siquiera podía leer los títulos.

Probé algunos orquestadores de programación, pero la mayoría eran aplicaciones Electron/Tauri y el rendimiento me molestaba. Además, simplemente prefiero la terminal ya que los orquestadores con GUI te encierran en su flujo de trabajo. Así que construí cmux como una app nativa de macOS en Swift/AppKit. Usa libghostty para el renderizado del terminal y lee tu configuración existente de Ghostty para temas, fuentes y colores.

Las principales adiciones son la barra lateral y el sistema de notificaciones. La barra lateral tiene pestañas verticales que muestran la rama de git, el directorio de trabajo, los puertos en escucha y el texto de la última notificación para cada espacio de trabajo. El sistema de notificaciones detecta secuencias de terminal (OSC 9/99/777) y tiene un CLI (`cmux notify`) que puedes conectar a los hooks de agentes para Claude Code, OpenCode, etc. Cuando un agente está esperando, su panel obtiene un anillo azul y la pestaña se ilumina en la barra lateral, para que pueda saber cuál me necesita entre divisiones y pestañas. ⌘⇧U salta a la notificación no leída más reciente.

El navegador integrado tiene una API programable portada de [agent-browser](https://github.com/vercel-labs/agent-browser). Los agentes pueden capturar el árbol de accesibilidad, obtener referencias de elementos, hacer clic, rellenar formularios y ejecutar JS. Puedes dividir un panel de navegador junto a tu terminal y hacer que Claude Code interactúe directamente con tu servidor de desarrollo.

Todo es programable a través del CLI y la API de socket — crear espacios de trabajo/pestañas, dividir paneles, enviar pulsaciones de teclas, abrir URLs en el navegador.

## Atajos de teclado

### Espacios de trabajo

| Atajo | Acción |
|----------|--------|
| ⌘ N | Nuevo espacio de trabajo |
| ⌘ 1–8 | Ir al espacio de trabajo 1–8 |
| ⌘ 9 | Ir al último espacio de trabajo |
| ⌃ ⌘ ] | Siguiente espacio de trabajo |
| ⌃ ⌘ [ | Espacio de trabajo anterior |
| ⌘ ⇧ W | Cerrar espacio de trabajo |
| ⌘ B | Alternar barra lateral |

### Superficies

| Atajo | Acción |
|----------|--------|
| ⌘ T | Nueva superficie |
| ⌘ ⇧ ] | Siguiente superficie |
| ⌘ ⇧ [ | Superficie anterior |
| ⌃ Tab | Siguiente superficie |
| ⌃ ⇧ Tab | Superficie anterior |
| ⌃ 1–8 | Ir a la superficie 1–8 |
| ⌃ 9 | Ir a la última superficie |
| ⌘ W | Cerrar superficie |

### Paneles divididos

| Atajo | Acción |
|----------|--------|
| ⌘ D | Dividir a la derecha |
| ⌘ ⇧ D | Dividir hacia abajo |
| ⌥ ⌘ ← → ↑ ↓ | Enfocar panel direccionalmente |
| ⌘ ⇧ H | Destellar panel enfocado |

### Navegador

| Atajo | Acción |
|----------|--------|
| ⌘ ⇧ L | Abrir navegador en división |
| ⌘ L | Enfocar barra de direcciones |
| ⌘ [ | Atrás |
| ⌘ ] | Adelante |
| ⌘ R | Recargar página |
| ⌥ ⌘ I | Abrir herramientas de desarrollo |

### Notificaciones

| Atajo | Acción |
|----------|--------|
| ⌘ I | Mostrar panel de notificaciones |
| ⌘ ⇧ U | Ir a la última no leída |

### Buscar

| Atajo | Acción |
|----------|--------|
| ⌘ F | Buscar |
| ⌘ G / ⌘ ⇧ G | Buscar siguiente / anterior |
| ⌘ ⇧ F | Ocultar barra de búsqueda |
| ⌘ E | Usar selección para buscar |

### Terminal

| Atajo | Acción |
|----------|--------|
| ⌘ K | Limpiar historial de desplazamiento |
| ⌘ C | Copiar (con selección) |
| ⌘ V | Pegar |
| ⌘ + / ⌘ - | Aumentar / disminuir tamaño de fuente |
| ⌘ 0 | Restablecer tamaño de fuente |

### Ventana

| Atajo | Acción |
|----------|--------|
| ⌘ ⇧ N | Nueva ventana |
| ⌘ , | Ajustes |
| ⌘ ⇧ , | Recargar configuración |
| ⌘ Q | Salir |

## Licencia

Este proyecto está licenciado bajo la Licencia Pública General Affero de GNU v3.0 o posterior (`AGPL-3.0-or-later`).

Consulta el archivo `LICENSE` para el texto completo.
