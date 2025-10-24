import { useEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import {
  type Theme,
  type ResolvedTheme,
  ThemeProviderContext,
} from "./theme-context";
import { useVSCodeSocket } from "@/contexts/vscode-socket/vscode-socket-context";

type DocumentWithStartViewTransition = Document & {
  startViewTransition?: (
    callback: () => void
  ) => ViewTransition;
};

type ThemeProviderProps = {
  children: React.ReactNode;
  defaultTheme?: Theme;
  storageKey?: string;
};

const getInitialResolvedTheme = (): ResolvedTheme => {
  if (typeof document === "undefined") {
    return "light";
  }
  return document.documentElement.classList.contains("dark")
    ? "dark"
    : "light";
};

export function ThemeProvider({
  children,
  defaultTheme = "system",
  storageKey = "vite-ui-theme",
  ...props
}: ThemeProviderProps) {
  const [theme, setThemeState] = useState<Theme>(
    () => (localStorage.getItem(storageKey) as Theme) || defaultTheme
  );
  const resolvedThemeRef = useRef<ResolvedTheme>(getInitialResolvedTheme());
  const [resolvedTheme, setResolvedTheme] = useState<ResolvedTheme>(
    resolvedThemeRef.current
  );
  const isInitialRenderRef = useRef(true);

  useEffect(() => {
    const root = window.document.documentElement;

    const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    const computeSystem = (): ResolvedTheme => (mediaQuery.matches ? "dark" : "light");
    const prefersReducedMotion = window
      .matchMedia("(prefers-reduced-motion: reduce)")
      .matches;

    const applyTheme = (
      next: ResolvedTheme,
      { withTransition }: { withTransition: boolean }
    ) => {
      const updateTheme = () => {
        root.classList.remove("light", "dark");
        root.classList.add(next);

        if (resolvedThemeRef.current !== next) {
          resolvedThemeRef.current = next;
          setResolvedTheme(next);
        }
      };

      const documentWithTransition = document as DocumentWithStartViewTransition;
      const startViewTransition = documentWithTransition.startViewTransition?.bind(
        documentWithTransition
      );
      const shouldAnimate =
        withTransition &&
        !prefersReducedMotion &&
        typeof startViewTransition === "function";

      if (shouldAnimate) {
        startViewTransition(() => {
          flushSync(() => {
            updateTheme();
          });
        });
        return;
      }

      updateTheme();
    };

    const shouldAnimate = !isInitialRenderRef.current;

    if (theme === "system") {
      const sys = computeSystem();
      applyTheme(sys, { withTransition: shouldAnimate });

      // Listen for system theme changes
      const handleChange = () => {
        const next = computeSystem();
        applyTheme(next, { withTransition: true });
      };

      mediaQuery.addEventListener("change", handleChange);
      isInitialRenderRef.current = false;
      return () => mediaQuery.removeEventListener("change", handleChange);
    } else {
      applyTheme(theme, { withTransition: shouldAnimate });
    }
    isInitialRenderRef.current = false;
  }, [theme]);

  const value = {
    theme,
    resolvedTheme,
    setTheme: (nextTheme: Theme) => {
      localStorage.setItem(storageKey, nextTheme);
      if (nextTheme === theme) {
        return;
      }
      setThemeState(nextTheme);
    },
    syncThemeToVSCode: (vscodeTheme: "dark" | "light") => {
      const { vscodeSocket, isVSCodeConnected } = useVSCodeSocket();
      if (vscodeSocket && isVSCodeConnected) {
        vscodeSocket.emit("vscode:set-theme", { theme: vscodeTheme }, (response) => {
          if (!response.success) {
            console.error("Failed to sync theme to VS Code:", response.error);
          }
        });
      }
    },
  };

  return (
    <ThemeProviderContext.Provider {...props} value={value}>
      {children}
    </ThemeProviderContext.Provider>
  );
}
