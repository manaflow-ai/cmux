"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";
import type { ReactNode } from "react";
import { Moon, Sun } from "lucide-react";

import { cn } from "@/lib/utils";

import {
  DEFAULT_THEME,
  THEME_COOKIE_NAME,
  type ThemePreference,
  isThemePreference,
} from "./theme";

const THEME_STORAGE_KEY = "prReviewTheme";

type ThemeContextValue = {
  theme: ThemePreference;
  setTheme: (theme: ThemePreference) => void;
  toggleTheme: () => void;
};

const ThemeContext = createContext<ThemeContextValue | null>(null);

export function PageThemeProvider({
  initialTheme,
  children,
}: {
  initialTheme?: ThemePreference | null;
  children: ReactNode;
}) {
  const [theme, setThemeState] = useState<ThemePreference>(
    initialTheme ?? DEFAULT_THEME
  );

  useEffect(() => {
    if (!initialTheme) {
      return;
    }

    setThemeState((current) =>
      current === initialTheme ? current : initialTheme
    );
  }, [initialTheme]);

  useEffect(() => {
    if (initialTheme && isThemePreference(initialTheme)) {
      return;
    }

    try {
      const stored = window.localStorage.getItem(THEME_STORAGE_KEY);
      if (isThemePreference(stored)) {
        setThemeState(stored);
      }
    } catch {
      // Access to localStorage can fail in non-browser environments; ignore.
    }
  }, [initialTheme]);

  const setTheme = useCallback((next: ThemePreference) => {
    setThemeState(next);
  }, []);

  const toggleTheme = useCallback(() => {
    setThemeState((current) => (current === "light" ? "dark" : "light"));
  }, []);

  useEffect(() => {
    const maxAgeSeconds = 60 * 60 * 24 * 365; // 1 year
    document.cookie = `${THEME_COOKIE_NAME}=${theme}; path=/; max-age=${maxAgeSeconds}; sameSite=lax`;

    try {
      window.localStorage.setItem(THEME_STORAGE_KEY, theme);
    } catch {
      // Ignore localStorage failures.
    }

    document.documentElement.classList.toggle("dark", theme === "dark");
    document.documentElement.dataset.prReviewTheme = theme;
  }, [theme]);

  const contextValue = useMemo(
    () => ({
      theme,
      setTheme,
      toggleTheme,
    }),
    [theme, setTheme, toggleTheme]
  );

  return (
    <ThemeContext.Provider value={contextValue}>
      <div className={cn(theme === "dark" && "dark", "transition-colors")}>
        {children}
      </div>
    </ThemeContext.Provider>
  );
}

export function usePageTheme(): ThemeContextValue {
  const value = useContext(ThemeContext);

  if (!value) {
    throw new Error("usePageTheme must be used within a PageThemeProvider");
  }

  return value;
}

export function ThemeToggleButton({ className }: { className?: string }) {
  const { theme, toggleTheme } = usePageTheme();
  const isDark = theme === "dark";

  return (
    <button
      type="button"
      onClick={toggleTheme}
      aria-pressed={isDark}
      aria-label={isDark ? "Switch to light mode" : "Switch to dark mode"}
      className={cn(
        "inline-flex items-center gap-1.5 rounded-md border border-neutral-300 bg-white px-3 py-1.5 text-xs font-medium text-neutral-700 transition hover:border-neutral-400 hover:text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-neutral-500 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-200 dark:hover:border-neutral-600 dark:hover:text-neutral-50 dark:focus-visible:ring-neutral-400 dark:focus-visible:ring-offset-neutral-900",
        className
      )}
    >
      {isDark ? (
        <Sun className="h-3.5 w-3.5" aria-hidden />
      ) : (
        <Moon className="h-3.5 w-3.5" aria-hidden />
      )}
      <span>{isDark ? "Light mode" : "Dark mode"}</span>
    </button>
  );
}
