import * as Dialog from "@radix-ui/react-dialog";
import { X } from "lucide-react";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type FormEvent,
} from "react";

import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

export interface CreateTeamFormValues {
  displayName: string;
  slug: string;
  invites: string[];
}

interface CreateTeamDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSubmit: (values: CreateTeamFormValues) => Promise<void>;
}

function slugify(input: string): string {
  return input
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48);
}

function parseInviteEmails(input: string): string[] {
  return input
    .split(/[\s,]+/)
    .map((email) => email.trim())
    .filter((email) => email.length > 0);
}

export function CreateTeamDialog({
  open,
  onOpenChange,
  onSubmit,
}: CreateTeamDialogProps) {
  const [displayName, setDisplayName] = useState("");
  const [slug, setSlug] = useState("");
  const [slugManuallyEdited, setSlugManuallyEdited] = useState(false);
  const [inviteInput, setInviteInput] = useState("");
  const [nameTouched, setNameTouched] = useState(false);
  const [slugTouched, setSlugTouched] = useState(false);
  const [submitAttempted, setSubmitAttempted] = useState(false);
  const [generalError, setGeneralError] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const nameInputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!open) {
      setDisplayName("");
      setSlug("");
      setInviteInput("");
      setSlugManuallyEdited(false);
      setNameTouched(false);
      setSlugTouched(false);
      setSubmitAttempted(false);
      setGeneralError(null);
      setIsSubmitting(false);
      return;
    }
    nameInputRef.current?.focus();
  }, [open]);

  useEffect(() => {
    if (!open) return;
    if (slugManuallyEdited) return;
    const generated = slugify(displayName);
    setSlug(generated);
  }, [displayName, slugManuallyEdited, open]);

  const displayNameError = useMemo(() => {
    const trimmed = displayName.trim();
    if (!trimmed) return "Team name is required";
    if (trimmed.length > 64) {
      return "Team name must be 64 characters or fewer";
    }
    return null;
  }, [displayName]);

  const slugError = useMemo(() => {
    const trimmed = slug.trim();
    if (!trimmed) return "Slug is required";
    if (trimmed.length < 3 || trimmed.length > 48) {
      return "Slug must be 3–48 characters long";
    }
    if (!/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(trimmed)) {
      return "Slug can contain lowercase letters, numbers, and hyphens";
    }
    return null;
  }, [slug]);

  const shouldShowNameError = (submitAttempted || nameTouched) && displayNameError;
  const shouldShowSlugError = (submitAttempted || slugTouched) && slugError;

  const handleSubmit = useCallback(
    async (event: FormEvent<HTMLFormElement>) => {
      event.preventDefault();
      setSubmitAttempted(true);
      setGeneralError(null);

      if (displayNameError || slugError) {
        setNameTouched(true);
        setSlugTouched(true);
        return;
      }

      setIsSubmitting(true);
      try {
        await onSubmit({
          displayName: displayName.trim(),
          slug: slug.trim(),
          invites: parseInviteEmails(inviteInput),
        });
        onOpenChange(false);
      } catch (error) {
        const message =
          error instanceof Error && error.message
            ? error.message
            : "Failed to create team. Please try again.";
        setGeneralError(message);
      } finally {
        setIsSubmitting(false);
      }
    },
    [displayName, displayNameError, inviteInput, onOpenChange, onSubmit, slug, slugError]
  );

  const resetSlug = useCallback(() => {
    setSlug(slugify(displayName));
    setSlugManuallyEdited(false);
  }, [displayName]);

  const inputClassName = (hasError: boolean) =>
    cn(
      "w-full rounded-lg border px-3 py-2 text-sm bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 focus:outline-none focus:ring-2 focus:border-transparent transition",
      hasError
        ? "border-red-500 focus:ring-red-500"
        : "border-neutral-300 dark:border-neutral-700 focus:ring-neutral-900/10 dark:focus:ring-neutral-100/20"
    );

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[var(--z-modal)] bg-neutral-950/50 backdrop-blur-sm" />
        <div className="fixed inset-0 z-[var(--z-modal)] flex items-center justify-center px-4 py-6">
          <Dialog.Content
            className="relative w-full max-w-lg rounded-2xl border border-neutral-200 bg-white p-6 shadow-2xl dark:border-neutral-800 dark:bg-neutral-950"
            onOpenAutoFocus={(event) => {
              event.preventDefault();
              nameInputRef.current?.focus();
            }}
          >
            <Dialog.Title className="text-lg font-semibold text-neutral-900 dark:text-neutral-100">
              Create a new team
            </Dialog.Title>
            <Dialog.Description className="mt-1 text-sm text-neutral-600 dark:text-neutral-400">
              Name your team, choose a URL slug, and optionally invite teammates.
            </Dialog.Description>

            <form className="mt-6 space-y-5" onSubmit={handleSubmit}>
              <div>
                <label
                  htmlFor="create-team-name"
                  className="block text-sm font-medium text-neutral-700 dark:text-neutral-300"
                >
                  Team name
                </label>
                <input
                  ref={nameInputRef}
                  id="create-team-name"
                  type="text"
                  value={displayName}
                  onChange={(event) => {
                    setDisplayName(event.target.value);
                  }}
                  onBlur={() => setNameTouched(true)}
                  placeholder="Rocket Labs"
                  autoComplete="organization"
                  className={inputClassName(Boolean(shouldShowNameError))}
                  aria-invalid={shouldShowNameError ? true : undefined}
                  aria-describedby={shouldShowNameError ? "create-team-name-error" : undefined}
                />
                <p className="mt-2 text-xs text-neutral-500 dark:text-neutral-400">
                  This is how your team will appear across cmux.
                </p>
                {shouldShowNameError ? (
                  <p
                    id="create-team-name-error"
                    className="mt-1 text-xs text-red-600 dark:text-red-500"
                  >
                    {displayNameError}
                  </p>
                ) : null}
              </div>

              <div>
                <div className="flex items-center justify-between">
                  <label
                    htmlFor="create-team-slug"
                    className="block text-sm font-medium text-neutral-700 dark:text-neutral-300"
                  >
                    Team slug
                  </label>
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    className="-mr-2 text-xs text-neutral-600 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-100"
                    onClick={resetSlug}
                    disabled={!slugManuallyEdited}
                  >
                    Reset
                  </Button>
                </div>
                <div className="mt-1 flex items-center gap-2">
                  <div className="text-sm text-neutral-500 dark:text-neutral-400">cmux.dev/</div>
                  <input
                    id="create-team-slug"
                    type="text"
                    value={slug}
                    onChange={(event) => {
                      setSlug(event.target.value);
                      setSlugManuallyEdited(true);
                    }}
                    onBlur={() => setSlugTouched(true)}
                    placeholder="rocket-labs"
                    className={cn(inputClassName(Boolean(shouldShowSlugError)), "flex-1")}
                    aria-invalid={shouldShowSlugError ? true : undefined}
                    aria-describedby={shouldShowSlugError ? "create-team-slug-error" : "create-team-slug-help"}
                  />
                </div>
                <p
                  id="create-team-slug-help"
                  className="mt-2 text-xs text-neutral-500 dark:text-neutral-400"
                >
                  Lowercase letters, numbers, and hyphens only. Must be 3–48 characters.
                </p>
                {shouldShowSlugError ? (
                  <p
                    id="create-team-slug-error"
                    className="mt-1 text-xs text-red-600 dark:text-red-500"
                  >
                    {slugError}
                  </p>
                ) : null}
              </div>

              <div>
                <label
                  htmlFor="create-team-invites"
                  className="block text-sm font-medium text-neutral-700 dark:text-neutral-300"
                >
                  Invite teammates (optional)
                </label>
                <textarea
                  id="create-team-invites"
                  value={inviteInput}
                  onChange={(event) => setInviteInput(event.target.value)}
                  placeholder="alice@example.com, bob@example.com"
                  className={cn(
                    inputClassName(false),
                    "mt-1 h-24 resize-none"
                  )}
                />
                <p className="mt-2 text-xs text-neutral-500 dark:text-neutral-400">
                  Separate email addresses with commas, spaces, or new lines. We’ll send each person an invite.
                </p>
              </div>

              {generalError ? (
                <div className="rounded-md border border-red-500/40 bg-red-50 px-3 py-2 text-sm text-red-700 dark:border-red-500/30 dark:bg-red-500/10 dark:text-red-400">
                  {generalError}
                </div>
              ) : null}

              <div className="flex items-center justify-end gap-3 pt-2">
                <Dialog.Close asChild>
                  <Button
                    type="button"
                    variant="ghost"
                    className="text-neutral-600 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-100"
                  >
                    Cancel
                  </Button>
                </Dialog.Close>
                <Button type="submit" disabled={isSubmitting}>
                  {isSubmitting ? "Creating…" : "Create team"}
                </Button>
              </div>
            </form>

            <Dialog.Close asChild>
              <button
                type="button"
                className="absolute right-4 top-4 rounded-full p-1 text-neutral-500 transition hover:bg-neutral-100 hover:text-neutral-900 focus:outline-none focus:ring-2 focus:ring-neutral-900/20 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-100 dark:focus:ring-neutral-100/20"
                aria-label="Close"
              >
                <X className="size-4" />
              </button>
            </Dialog.Close>
          </Dialog.Content>
        </div>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
