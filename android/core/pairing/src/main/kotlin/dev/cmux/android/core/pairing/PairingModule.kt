package dev.cmux.android.core.pairing

import android.content.Context
import androidx.room.Room
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object PairingModule {
    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): CmuxDatabase =
        Room.databaseBuilder(context, CmuxDatabase::class.java, "cmux.db")
            .fallbackToDestructiveMigration()
            .build()

    @Provides
    fun providePairedMacDao(db: CmuxDatabase): PairedMacDao = db.pairedMacDao()
}
